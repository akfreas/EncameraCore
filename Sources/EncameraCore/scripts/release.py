#!/usr/bin/env python3
"""Release driver — preflight checks + ASC release flow for the iOS app.

Run:

    python release.py [--credentials PATH] [--skip-preflights] [--dry-run] [--interactive]

Preflights (cheap/local checks first, network calls last):
  1. HEAD is on the 'main' branch.
  2. Working tree has no staged/unstaged changes.
  3. Local main matches origin/main (no diverging commits).
  4. app_store.yml has changed since the last git tag (what's new updated).
  5. All .lproj files are in sync with en.lproj (no missing translations).
  6. No TestFlight builds for the release version are still PROCESSING.
  7. No active (PENDING/RUNNING) build runs on the "Build for TestFlight"
     Xcode Cloud workflow.

Release steps (after preflights pass):
  1. Run the Localizer (push translated metadata to ASC).
  2. git tag <version>, then interactive y/N to push.
  3. Pick the most recently uploaded VALID TestFlight build for the version
     and attach it to the App Store version.
  4. Set releaseType=MANUAL on the version.
  5. Submit the version for review.

With --interactive, the driver pauses for y/N confirmation on:
  • the English whats_new text before running the Localizer
  • the chosen TestFlight build before attaching it to the App Store version

Requires the `asc` library: pip install -e scripts/asc
"""

import argparse
import subprocess
import sys
from pathlib import Path

try:
    from asc.auth import Credentials
    from asc.client import ASCClient
    from asc.releases import (
        find_editable_version,
        set_build_for_version,
        set_version_release_type,
        submit_for_review,
    )
    from asc.testflight import list_builds_for_version
    from asc.xcode_cloud.build_runs import list_build_runs_for_workflow
except ImportError:
    print("Missing required package 'asc'. Install with: pip install -e scripts/asc")
    sys.exit(1)

SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parents[3]
APP_STORE_YML = SCRIPT_DIR / "app_store_localization" / "app_store.yml"
EN_LPROJ = SCRIPT_DIR.parent / "Resources" / "en.lproj"
LOCALIZATION_DIR = SCRIPT_DIR / "app_store_localization"

# Xcode Cloud "Build for TestFlight" workflow — must be idle before we cut a
# release, otherwise the build we're about to attach may be superseded by
# whatever is mid-flight.
TESTFLIGHT_WORKFLOW_ID = "0fe065ac-1630-4bd4-9158-c43af076cbd9"
ACTIVE_BUILD_PROGRESS = {"PENDING", "RUNNING"}

# Make Localizer importable
sys.path.insert(0, str(LOCALIZATION_DIR))


def confirm(prompt):
    """Prompt y/N; return True on y/yes, False otherwise (default No)."""
    return input(f"{prompt} (y/N): ").strip().lower() in ("y", "yes")


def resolve_credentials_path(arg_path):
    if arg_path:
        if not Path(arg_path).exists():
            print(f"Credentials file not found: {arg_path}")
            sys.exit(1)
        return arg_path
    candidates = [
        SCRIPT_DIR / "app_store_localization" / "credentials.yml",
        SCRIPT_DIR / "credentials.yml",
        Path.cwd() / "credentials.yml",
    ]
    for c in candidates:
        if c.exists():
            return str(c)
    print("Could not find credentials.yml. Specify with --credentials.")
    sys.exit(1)


# --- preflights ---------------------------------------------------------------


def preflight_on_main_branch():
    """True if HEAD is on the 'main' branch.

    Releases must be cut from main — if HEAD is on a feature branch (or detached),
    the tag would land in the wrong place.
    """
    result = subprocess.run(
        ["git", "rev-parse", "--abbrev-ref", "HEAD"],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
        check=True,
    )
    branch = result.stdout.strip()
    if branch != "main":
        print(f"  current branch: {branch}")
        return False
    return True


def preflight_clean_tree():
    """True if there are no staged or unstaged changes to tracked files.

    Untracked files (status code ``??``) are tolerated — the release tag will
    only capture committed state, so untracked scratch files are harmless.
    """
    unstaged = subprocess.run(
        ["git", "diff", "--quiet"], cwd=REPO_ROOT, check=False
    )
    staged = subprocess.run(
        ["git", "diff", "--cached", "--quiet"], cwd=REPO_ROOT, check=False
    )
    if unstaged.returncode == 0 and staged.returncode == 0:
        return True

    status = subprocess.run(
        ["git", "status", "--porcelain"],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
        check=True,
    )
    dirty = [line for line in status.stdout.splitlines() if not line.startswith("??")]
    if not dirty:
        return True
    for line in dirty:
        print(f"  {line}")
    return False


def preflight_local_main_matches_remote():
    """True if local main is at the same commit as origin/main.

    Runs `git fetch origin main` first so the comparison reflects the current
    remote state, not a stale FETCH_HEAD. Returns False if local is ahead,
    behind, or diverged.
    """
    fetch = subprocess.run(
        ["git", "fetch", "origin", "main"],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
        check=False,
    )
    if fetch.returncode != 0:
        print(f"  git fetch origin main failed: {fetch.stderr.strip()}")
        return False

    local = subprocess.run(
        ["git", "rev-parse", "main"],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
        check=False,
    )
    remote = subprocess.run(
        ["git", "rev-parse", "origin/main"],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
        check=False,
    )
    if local.returncode != 0 or remote.returncode != 0:
        print("  could not resolve main / origin/main SHAs")
        return False

    local_sha = local.stdout.strip()
    remote_sha = remote.stdout.strip()
    if local_sha == remote_sha:
        return True

    counts = subprocess.run(
        ["git", "rev-list", "--left-right", "--count", "main...origin/main"],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
        check=False,
    )
    if counts.returncode == 0:
        ahead, behind = counts.stdout.strip().split()
        print(f"  local main is ahead {ahead}, behind {behind} vs origin/main")
    print(f"  local  {local_sha}")
    print(f"  remote {remote_sha}")
    return False


def preflight_app_store_yml_changed(yml_path, last_tag):
    """True if app_store.yml differs from its content at ``last_tag``.

    Returns None when git diff itself fails (distinguishes from False = no changes).
    """
    diff = subprocess.run(
        ["git", "diff", last_tag, "--", str(yml_path)],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
        check=False,
    )
    if diff.returncode != 0:
        print(f"  git diff failed: {diff.stderr.strip()}")
        return None
    return bool(diff.stdout.strip())


def preflight_strings_in_sync(en_lproj):
    """True if every .lproj has every key from en.lproj/Localizable.strings."""
    # Lazy import — string_diff pulls in openai/keyring/etc. that aren't needed
    # elsewhere in this script. Importing here keeps the failure modes localized.
    from string_diff import get_localization_status, load_strings_from_file

    master_file = en_lproj / "Localizable.strings"
    if not master_file.exists():
        print(f"  master file does not exist: {master_file}")
        return False

    master = load_strings_from_file(master_file)
    _, localizations, missing_by_lang = get_localization_status(master, en_lproj)

    if not localizations:
        print("  no .lproj siblings found — nothing to compare against")
        return False

    if missing_by_lang:
        for lang_code, info in missing_by_lang.items():
            print(f"  {lang_code} missing {len(info['missing_keys'])} key(s)")
        return False
    return True


def preflight_no_pending_builds(client, app_id, version_string):
    """True if no TestFlight builds for ``version_string`` are still PROCESSING."""
    pending = list_builds_for_version(
        client, app_id, version_string, processing_state="PROCESSING"
    )
    if pending:
        print(f"  {len(pending)} build(s) still PROCESSING for v{version_string}:")
        for b in pending:
            attrs = b.get("attributes", {})
            print(f"    build {attrs.get('version')} uploaded {attrs.get('uploadedDate')}")
        return False
    return True


def preflight_no_active_xcode_cloud_builds(client, workflow_id):
    """True if the given Xcode Cloud workflow has no PENDING/RUNNING build runs.

    Pulls the most recent runs (sorted by -number) and flags any whose
    executionProgress is still in :data:`ACTIVE_BUILD_PROGRESS`. A small limit
    is enough because completed runs are interleaved by start time, not by
    completion — the newest active run will always be near the top.
    """
    runs = list_build_runs_for_workflow(client, workflow_id, limit=20)
    active = [r for r in runs if r.execution_progress in ACTIVE_BUILD_PROGRESS]
    if active:
        print(f"  {len(active)} active build run(s) on workflow {workflow_id}:")
        for r in active:
            print(
                f"    #{r.number} {r.execution_progress} "
                f"started={r.started_date or '-'} sha={(r.source_commit_sha or '')[:8]}"
            )
        return False
    return True


# --- release steps ------------------------------------------------------------


def run_localize(config_path, credentials_path, version_id=None):
    from localize import Localizer
    result = Localizer(
        str(config_path),
        credentials_path,
        version_id=version_id,
        skip_confirmation=True,
    ).run()
    if not result:
        print("Localizer did not complete successfully. Aborting release.")
        sys.exit(1)


def confirm_whats_new(yml_path):
    """Print the English whats_new from ``yml_path`` and prompt y/N to proceed."""
    import yaml

    with open(yml_path) as f:
        data = yaml.safe_load(f)
    whats_new = (data.get("listing") or {}).get("whats_new")
    if not whats_new:
        print(f"  No whats_new found in {yml_path}. Aborting.")
        sys.exit(1)
    print("  --- whats_new (English) ---")
    for line in whats_new.rstrip().splitlines():
        print(f"  {line}")
    print("  --- end whats_new ---")
    if not confirm("Use this whats_new for the release?"):
        print("  Aborted by user — update whats_new in app_store.yml and re-run.")
        sys.exit(1)


def tag_release(version_string):
    """Create the git tag locally, then prompt y/N to push to origin."""
    existing = subprocess.run(
        ["git", "tag", "-l", version_string],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
        check=True,
    ).stdout.strip()
    if existing:
        print(f"  Tag {version_string} already exists locally — skipping creation.")
    else:
        subprocess.run(
            ["git", "tag", version_string],
            cwd=REPO_ROOT,
            check=True,
        )
        print(f"  Created git tag {version_string}")

    answer = input(f"Push tag {version_string} to origin now? (y/N): ").strip().lower()
    if answer in ("y", "yes"):
        try:
            subprocess.run(
                ["git", "push", "origin", version_string],
                cwd=REPO_ROOT,
                check=True,
            )
            print(f"  Pushed {version_string} to origin")
        except subprocess.CalledProcessError as e:
            print(f"  WARNING: git push failed (exit {e.returncode}). "
                  f"Push manually with: git push origin {version_string}")
    else:
        print(f"  Skipped push — run 'git push origin {version_string}' when ready")


def select_and_attach_build(
    client, app_id, version_id, version_string, *, dry_run=False, interactive=False
):
    valid = list_builds_for_version(
        client, app_id, version_string, processing_state="VALID"
    )
    if not valid:
        print(f"  No VALID builds for v{version_string} — cannot proceed.")
        sys.exit(1)

    valid.sort(
        key=lambda b: b.get("attributes", {}).get("uploadedDate") or "",
        reverse=True,
    )
    latest = valid[0]
    build_id = latest["id"]
    build_number = latest.get("attributes", {}).get("version", "?")
    uploaded = latest.get("attributes", {}).get("uploadedDate", "?")
    print(f"  Latest VALID build: {build_number} (uploaded {uploaded}, id={build_id})")

    if dry_run:
        print("  [dry-run] would attach this build to the version")
        return build_id

    if interactive and not confirm(
        f"Attach build {build_number} (uploaded {uploaded}) to v{version_string}?"
    ):
        print("  Aborted by user — re-run when the correct build is uploaded.")
        sys.exit(1)

    set_build_for_version(client, version_id, build_id)
    print(f"  Attached build {build_number} to version {version_string}")
    return build_id


# --- main ---------------------------------------------------------------------


def main():
    parser = argparse.ArgumentParser(
        description="Run preflight checks and drive the iOS release flow on App Store Connect.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--credentials", type=str, help="Path to credentials.yml")
    parser.add_argument(
        "--skip-preflights",
        action="store_true",
        help="Skip all preflight checks (use with care)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Run preflights and print planned actions, but do not localize/tag/attach/submit",
    )
    parser.add_argument(
        "--interactive",
        action="store_true",
        help="Prompt for confirmation on the whats_new text and the selected TestFlight build",
    )
    args = parser.parse_args()

    credentials_path = resolve_credentials_path(args.credentials)

    print("=== Release Driver ===")
    if args.dry_run:
        print("*** DRY RUN — no localize, tag, attach, release-type or submit will run ***")
    if args.interactive:
        print("*** INTERACTIVE — will prompt to confirm whats_new and selected build ***")
    print()

    # --- cheap local preflights run first so we fail fast without hitting the API ---
    try:
        last_tag = subprocess.run(
            ["git", "describe", "--tags", "--abbrev=0"],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()
    except subprocess.CalledProcessError:
        print(
            "Could not determine the last git tag (no tags in this repository?).\n"
            "Tag the repo at least once before running preflights, or use --skip-preflights."
        )
        sys.exit(1)
    print(f"Last git tag: {last_tag}")
    print()

    if not args.skip_preflights:
        print("[1/7] On the main branch?")
        if not preflight_on_main_branch():
            print(
                "  FAIL: releases must be cut from main. Merge to main and re-run, "
                "or use --skip-preflights if you really know what you're doing."
            )
            sys.exit(1)
        print("  OK")
        print()

        print("[2/7] Working tree clean (no staged or unstaged changes)?")
        if not preflight_clean_tree():
            print(
                "  FAIL: working tree has uncommitted changes. Commit or stash them "
                "before releasing — the tag must capture exactly what's on HEAD."
            )
            sys.exit(1)
        print("  OK")
        print()

        print("[3/7] Local main matches origin/main?")
        if not preflight_local_main_matches_remote():
            print(
                "  FAIL: local main has diverged from origin/main. Push or pull "
                "so they match before releasing — the tag must point at what's on origin."
            )
            sys.exit(1)
        print("  OK")
        print()

        print(f"[4/7] app_store.yml changed since tag {last_tag}?")
        yml_changed = preflight_app_store_yml_changed(APP_STORE_YML, last_tag)
        if yml_changed is None:
            print("  FAIL: could not run git diff — check REPO_ROOT and tag validity.")
            sys.exit(1)
        if not yml_changed:
            print(
                f"  FAIL: app_store.yml has no changes since {last_tag}. "
                "Update the 'whats_new' (and any other release-relevant fields) "
                "before releasing."
            )
            sys.exit(1)
        print("  OK")
        print()

        print("[5/7] All .lproj files in sync with en.lproj?")
        if not preflight_strings_in_sync(EN_LPROJ):
            print(
                "  FAIL: missing translations. Run scripts/string_diff.py to "
                "translate the missing keys."
            )
            sys.exit(1)
        print("  OK")
        print()
    else:
        print("Skipping local preflights (--skip-preflights)")
        print()

    # --- ASC-dependent setup (needed for the remaining preflights + release) ---
    print(f"Loading credentials from: {credentials_path}")
    creds = Credentials.load(credentials_path)
    client = ASCClient(creds)
    app_id = client.resolve_app_id()
    print(f"  app_id={app_id} bundle_id={creds.bundle_id}")
    print()

    print("Resolving release version from ASC...")
    version = find_editable_version(client, app_id)
    if version is None:
        print(
            "No editable appStoreVersion found on ASC. Create a new version on App "
            "Store Connect (PREPARE_FOR_SUBMISSION) before running this script."
        )
        sys.exit(1)
    version_string = version.version_string
    print(
        f"  Releasing v{version_string} "
        f"(state={version.state}, release_type={version.release_type or 'unset'}, "
        f"build={version.build_version or '-'})"
    )
    print()

    if not args.skip_preflights:
        print(f"[6/7] No PROCESSING TestFlight builds for v{version_string}?")
        if not preflight_no_pending_builds(client, app_id, version_string):
            print(
                "  FAIL: there are TestFlight builds still being processed by Apple. "
                "Wait for them to finish before releasing."
            )
            sys.exit(1)
        print("  OK")
        print()

        print("[7/7] No active build runs on the TestFlight Xcode Cloud workflow?")
        if not preflight_no_active_xcode_cloud_builds(client, TESTFLIGHT_WORKFLOW_ID):
            print(
                "  FAIL: an Xcode Cloud build is still running on the TestFlight "
                "workflow. Wait for it to finish (or cancel it) before releasing."
            )
            sys.exit(1)
        print("  OK")
        print()
    else:
        print("Skipping ASC preflights (--skip-preflights)")
        print()

    # --- release ---
    if args.dry_run:
        print("=== Dry-run release plan ===")
        print(f"  1. Run Localizer on {APP_STORE_YML}")
        print(f"  2. git tag {version_string} (then prompt to push)")
        print(f"  3. attach latest VALID build:")
        select_and_attach_build(
            client, app_id, version.id, version_string,
            dry_run=True, interactive=args.interactive,
        )
        print(f"  4. set releaseType=MANUAL on version {version.id}")
        print(f"  5. submit version {version.id} for review")
        print()
        print("Dry run complete — no changes made.")
        return

    if args.interactive:
        print("[release 0/5] Confirm whats_new (English)...")
        confirm_whats_new(APP_STORE_YML)
        print()

    print(f"[release 1/5] Pushing translated metadata via Localizer...")
    run_localize(APP_STORE_YML, credentials_path, version_id=version.id)
    print()

    print(f"[release 2/5] Tagging git as {version_string}...")
    tag_release(version_string)
    print()

    print(f"[release 3/5] Selecting and attaching latest VALID build...")
    select_and_attach_build(
        client, app_id, version.id, version_string, interactive=args.interactive,
    )
    print()

    print(f"[release 4/5] Setting releaseType=MANUAL...")
    set_version_release_type(client, version.id, "MANUAL")
    print(f"  releaseType set to MANUAL")
    print()

    print(f"[release 5/5] Submitting v{version_string} for review...")
    submit_for_review(client, app_id, version.id)
    print(f"  Submitted v{version_string} for review.")


if __name__ == "__main__":
    main()
