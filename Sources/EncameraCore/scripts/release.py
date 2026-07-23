#!/usr/bin/env python3
"""Release driver — preflight checks + ASC release flow for the iOS app.

Run:

    python release.py [--credentials PATH] [--skip-preflights] [--dry-run] [--interactive]

Preflights (cheap/local checks first, network calls last):
  1. HEAD is on RELEASE_BRANCH (see module constants).
  2. Working tree has no staged/unstaged changes.
  3. Local RELEASE_BRANCH matches origin/RELEASE_BRANCH (no diverging commits).
  4. app_store.yml has changed since the last git tag (what's new updated).
  5. All .lproj files are in sync with en.lproj (no missing translations).
  6. The version we're targeting lines up everywhere: project.yml
     marketing_version == the editable ASC version == a VALID TestFlight build.
  7. No TestFlight builds for the release version are still PROCESSING.
  8. No active (PENDING/RUNNING) build runs on the "Build for TestFlight"
     Xcode Cloud workflow.

Release steps (after preflights pass):
  1. Run the Localizer (push translated metadata to ASC) — skipped when the
     translatable strings in app_store.yml are unchanged since the last
     successful push (a gitignored hash cache saves the OpenAI tokens). After a
     successful push the strings hash is recorded as the source of truth for the
     next run. Use --force-localize to translate regardless.
  2. Pick the most recently uploaded VALID TestFlight build for the version.
     Any build already attached (e.g. from a previous run) is detached first,
     then the freshest build is attached to supersede it — avoiding ASC errors.
  3. Set releaseType=MANUAL on the version.
  4. Stage the version on a review submission — this leaves the app in the
     "Ready for Review" state, fully prepared but NOT yet sent to Apple.
  5. Prompt y/N to fully submit for review. On "yes" the submission is
     confirmed and sent to Apple; on "no" the app is left "Ready for Review"
     for you to submit manually from App Store Connect.
  6. Finally, git tag <version> and prompt y/N to push. The tag comes last —
     regardless of whether the release was actually submitted — so it marks a
     fully-prepared release rather than a mid-flight state.

With --interactive, the driver also pauses for y/N confirmation on:
  • the English whats_new text before running the Localizer
  • the chosen TestFlight build before attaching it to the App Store version

Requires the `asc` library: pip install -e scripts/asc
"""

import argparse
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path

try:
    from asc.auth import Credentials
    from asc.client import ASCClient
    from asc.releases import (
        clear_build_for_version,
        confirm_review_submission,
        find_editable_version,
        prepare_review_submission,
        set_build_for_version,
        set_version_release_type,
    )
    from asc.testflight import list_builds_for_version, list_builds_with_versions
    from asc.xcode_cloud.build_runs import list_build_runs_for_workflow
except ImportError:
    print("Missing required package 'asc'. Install with: pip install -e scripts/asc")
    sys.exit(1)

SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parents[3]
# project.yml holds the single source of truth for the marketing version the
# binary is stamped with (x-version-settings.marketing_version). The release
# must target exactly this version on ASC and TestFlight.
PROJECT_YML = REPO_ROOT / "project.yml"
APP_STORE_YML = SCRIPT_DIR / "app_store_localization" / "app_store.yml"
EN_LPROJ = SCRIPT_DIR.parent / "Resources" / "en.lproj"
LOCALIZATION_DIR = SCRIPT_DIR / "app_store_localization"

# Cache of the hash of the last set of App Store strings we successfully pushed
# to ASC. Gitignored — it's a per-machine token-saving cache, not source of
# truth. If the current app_store.yml strings hash to this value, translation is
# skipped (nothing changed since the last successful push). See EncameraCore/.gitignore.
LOCALIZED_HASH_FILE = SCRIPT_DIR / ".last_localized.hash"

# Xcode Cloud "Build for TestFlight" workflow — must be idle before we cut a
# release, otherwise the build we're about to attach may be superseded by
# whatever is mid-flight.
TESTFLIGHT_WORKFLOW_ID = "0fe065ac-1630-4bd4-9158-c43af076cbd9"
ACTIVE_BUILD_PROGRESS = {"PENDING", "RUNNING"}

# Git branch releases are cut from; local must match origin/<RELEASE_BRANCH>.
RELEASE_BRANCH = "release"
ORIGIN_RELEASE_BRANCH = f"origin/{RELEASE_BRANCH}"

# Make Localizer importable
sys.path.insert(0, str(LOCALIZATION_DIR))


def confirm(prompt):
    """Prompt y/N; return True on y/yes, False otherwise (default No)."""
    return input(f"{prompt} (y/N): ").strip().lower() in ("y", "yes")


def read_marketing_version(project_yml=PROJECT_YML):
    """Return the marketing_version string from project.yml, or None if unreadable.

    Reads the ``x-version-settings.marketing_version`` YAML anchor line
    directly with a regex rather than parsing the whole file — project.yml is an
    XcodeGen spec that yaml.safe_load chokes on (custom !-tags / anchors), and
    this value is the single source of truth for the version the binary carries.
    """
    try:
        text = project_yml.read_text()
    except OSError as e:
        print(f"  could not read {project_yml}: {e}")
        return None
    m = re.search(
        r'^\s*marketing_version:\s*&\w+\s*"?([^"\s]+)"?',
        text,
        re.MULTILINE,
    )
    if not m:
        print(f"  could not find marketing_version in {project_yml}")
        return None
    return m.group(1)


def compute_localization_hash(yml_path=APP_STORE_YML):
    """Hash the translatable App Store strings in ``yml_path``, or None if unreadable.

    The Localizer translates the ``listing`` fields (description, promotional_text,
    whats_new, keywords) into every ``target_languages`` locale. Hashing exactly
    those inputs — plus the language set and base language — lets us detect when a
    re-run would produce identical translations and skip the (token-expensive)
    OpenAI calls entirely. Serialized canonically (sorted keys) so the hash is
    stable regardless of YAML key order.
    """
    import yaml

    try:
        with open(yml_path) as f:
            data = yaml.safe_load(f)
    except OSError as e:
        print(f"  could not read {yml_path}: {e}")
        return None
    payload = {
        "listing": (data or {}).get("listing") or {},
        "target_languages": (data or {}).get("target_languages") or [],
        "base_language": (data or {}).get("base_language"),
    }
    canonical = json.dumps(payload, sort_keys=True, ensure_ascii=False)
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def read_stored_localization_hash(path=LOCALIZED_HASH_FILE):
    """Return the hash recorded after the last successful push, or None."""
    try:
        return path.read_text().strip()
    except OSError:
        return None


def write_stored_localization_hash(digest, path=LOCALIZED_HASH_FILE):
    """Record ``digest`` as the source of truth for the next run's skip check."""
    try:
        path.write_text(digest + "\n")
    except OSError as e:
        print(f"  WARNING: could not write localization hash to {path}: {e}")


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


def preflight_on_release_branch():
    f"""True if HEAD is on the '{RELEASE_BRANCH}' branch.

    Releases must be cut from {RELEASE_BRANCH} — if HEAD is on a feature branch (or detached),
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
    if branch != RELEASE_BRANCH:
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


def preflight_local_release_matches_remote():
    f"""True if local {RELEASE_BRANCH} is at the same commit as {ORIGIN_RELEASE_BRANCH}.

    Runs `git fetch origin {RELEASE_BRANCH}` first so the comparison reflects the current
    remote state, not a stale FETCH_HEAD. Returns False if local is ahead,
    behind, or diverged.
    """
    fetch = subprocess.run(
        ["git", "fetch", "origin", RELEASE_BRANCH],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
        check=False,
    )
    if fetch.returncode != 0:
        print(f"  git fetch origin {RELEASE_BRANCH} failed: {fetch.stderr.strip()}")
        return False

    local = subprocess.run(
        ["git", "rev-parse", RELEASE_BRANCH],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
        check=False,
    )
    remote = subprocess.run(
        ["git", "rev-parse", ORIGIN_RELEASE_BRANCH],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
        check=False,
    )
    if local.returncode != 0 or remote.returncode != 0:
        print(f"  could not resolve {RELEASE_BRANCH} / {ORIGIN_RELEASE_BRANCH} SHAs")
        return False

    local_sha = local.stdout.strip()
    remote_sha = remote.stdout.strip()
    if local_sha == remote_sha:
        return True

    rev_range = f"{RELEASE_BRANCH}...{ORIGIN_RELEASE_BRANCH}"
    counts = subprocess.run(
        ["git", "rev-list", "--left-right", "--count", rev_range],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
        check=False,
    )
    if counts.returncode == 0:
        ahead, behind = counts.stdout.strip().split()
        print(
            f"  local {RELEASE_BRANCH} is ahead {ahead}, behind {behind} "
            f"vs {ORIGIN_RELEASE_BRANCH}"
        )
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


def preflight_target_version_matches(client, app_id, version_string, marketing_version):
    """True if the target version is consistent across repo, ASC, and TestFlight.

    Three things must agree, or we'd cut a release for the wrong version:
      1. project.yml ``marketing_version`` (what the binary is stamped with)
         equals the editable ASC ``version_string`` we're about to release.
      2. TestFlight has at least one VALID (fully processed) build whose
         marketing version equals ``version_string`` — i.e. a build we can
         actually attach and submit.

    Prints the specific mismatch and returns False on any disagreement.
    """
    ok = True

    if marketing_version is None:
        # read_marketing_version already printed why.
        ok = False
    elif marketing_version != version_string:
        print(
            f"  MISMATCH: project.yml marketing_version is {marketing_version}, "
            f"but the editable ASC version is {version_string}. "
            "Bump marketing_version in project.yml (or fix the ASC version) so they match."
        )
        ok = False
    else:
        print(f"  project.yml marketing_version {marketing_version} matches ASC version")

    valid = list_builds_for_version(
        client, app_id, version_string, processing_state="VALID"
    )
    if not valid:
        print(
            f"  MISMATCH: no VALID TestFlight build found for v{version_string}. "
            "The version on TestFlight does not match the version being released — "
            "wait for the matching build to finish processing (or upload it)."
        )
        # Surface what IS on TestFlight so the mismatch is obvious.
        others = list_builds_with_versions(client, app_id, limit=20)
        seen = []
        for b in others:
            v = b.get("_app_version")
            state = b.get("attributes", {}).get("processingState")
            if v and (v, state) not in seen:
                seen.append((v, state))
        if seen:
            print("  TestFlight currently has builds for:")
            for v, state in seen[:10]:
                print(f"    v{v} ({state})")
        ok = False
    else:
        newest = max(
            valid, key=lambda b: b.get("attributes", {}).get("uploadedDate") or ""
        )
        attrs = newest.get("attributes", {})
        print(
            f"  VALID TestFlight build for v{version_string}: "
            f"{attrs.get('version')} (uploaded {attrs.get('uploadedDate')})"
        )

    return ok


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
    client, app_id, version_id, version_string, *,
    current_build_id=None, dry_run=False, interactive=False,
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

    already_attached = current_build_id == build_id

    if dry_run:
        if already_attached:
            print("  [dry-run] latest build is already attached — nothing to do")
        elif current_build_id:
            print(
                f"  [dry-run] would detach current build ({current_build_id}) "
                "then attach the latest build to the version"
            )
        else:
            print("  [dry-run] would attach this build to the version")
        return build_id

    if already_attached:
        print(f"  Build {build_number} is already attached to v{version_string} — leaving as-is")
        return build_id

    if interactive and not confirm(
        f"Attach build {build_number} (uploaded {uploaded}) to v{version_string}?"
    ):
        print("  Aborted by user — re-run when the correct build is uploaded.")
        sys.exit(1)

    # A stale build attached from a previous run would make the set below fail,
    # so detach it first, then attach the freshest VALID build to supersede it.
    if current_build_id:
        clear_build_for_version(client, version_id)
        print(f"  Detached previously-attached build ({current_build_id})")

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
    parser.add_argument(
        "--force-localize",
        action="store_true",
        help="Re-translate and push metadata even if the strings are unchanged since the last run",
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
        print(f"[1/8] On the {RELEASE_BRANCH} branch?")
        if not preflight_on_release_branch():
            print(
                f"  FAIL: releases must be cut from {RELEASE_BRANCH}. "
                f"Check out {RELEASE_BRANCH} and re-run, "
                "or use --skip-preflights if you really know what you're doing."
            )
            sys.exit(1)
        print("  OK")
        print()

        print("[2/8] Working tree clean (no staged or unstaged changes)?")
        if not preflight_clean_tree():
            print(
                "  FAIL: working tree has uncommitted changes. Commit or stash them "
                "before releasing — the tag must capture exactly what's on HEAD."
            )
            sys.exit(1)
        print("  OK")
        print()

        print(f"[3/8] Local {RELEASE_BRANCH} matches {ORIGIN_RELEASE_BRANCH}?")
        if not preflight_local_release_matches_remote():
            print(
                f"  FAIL: local {RELEASE_BRANCH} has diverged from {ORIGIN_RELEASE_BRANCH}. "
                "Push or pull so they match before releasing — the tag must point at what's on origin."
            )
            sys.exit(1)
        print("  OK")
        print()

        print(f"[4/8] app_store.yml changed since tag {last_tag}?")
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

        print("[5/8] All .lproj files in sync with en.lproj?")
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
        marketing_version = read_marketing_version()
        print(
            f"[6/8] Target version matches everywhere "
            f"(project.yml {marketing_version or '?'} == ASC {version_string} == a VALID build)?"
        )
        if not preflight_target_version_matches(
            client, app_id, version_string, marketing_version
        ):
            print(
                "  FAIL: the version we're releasing does not line up across "
                "project.yml, App Store Connect, and TestFlight. Reconcile them "
                "before releasing — see the mismatch above."
            )
            sys.exit(1)
        print("  OK")
        print()

        print(f"[7/8] No PROCESSING TestFlight builds for v{version_string}?")
        if not preflight_no_pending_builds(client, app_id, version_string):
            print(
                "  FAIL: there are TestFlight builds still being processed by Apple. "
                "Wait for them to finish before releasing."
            )
            sys.exit(1)
        print("  OK")
        print()

        print("[8/8] No active build runs on the TestFlight Xcode Cloud workflow?")
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
    current_hash = compute_localization_hash(APP_STORE_YML)
    stored_hash = read_stored_localization_hash()
    localize_unchanged = bool(
        current_hash and stored_hash and current_hash == stored_hash
    )

    if args.dry_run:
        print("=== Dry-run release plan ===")
        if localize_unchanged and not args.force_localize:
            print(f"  1. SKIP Localizer — strings unchanged since last push "
                  f"(hash {current_hash[:12]})")
        else:
            print(f"  1. Run Localizer on {APP_STORE_YML}, then record strings hash")
        print(f"  2. attach latest VALID build (superseding any attached build):")
        select_and_attach_build(
            client, app_id, version.id, version_string,
            current_build_id=version.build_id,
            dry_run=True, interactive=args.interactive,
        )
        print(f"  3. set releaseType=MANUAL on version {version.id}")
        print(f"  4. stage version {version.id} on a review submission (Ready for Review)")
        print(f"  5. prompt to fully submit for review (confirm the submission)")
        print(f"  6. git tag {version_string} (then prompt to push)")
        print()
        print("Dry run complete — no changes made.")
        return

    if args.interactive:
        print("[release 0/6] Confirm whats_new (English)...")
        confirm_whats_new(APP_STORE_YML)
        print()

    print(f"[release 1/6] Pushing translated metadata via Localizer...")
    if localize_unchanged and not args.force_localize:
        print(
            f"  App Store strings unchanged since the last successful push "
            f"(hash {current_hash[:12]}). Skipping translation to save tokens."
        )
        print(
            f"  (delete {LOCALIZED_HASH_FILE.name} or pass --force-localize to re-translate.)"
        )
    else:
        if stored_hash and current_hash and stored_hash != current_hash:
            print("  Strings changed since the last push — re-translating.")
        elif args.force_localize:
            print("  --force-localize set — re-translating regardless of the hash.")
        run_localize(APP_STORE_YML, credentials_path, version_id=version.id)
        # Only record the hash once ALL translated strings have been written to
        # ASC (run_localize aborts the whole release on failure), so the next run
        # trusts it as the source of truth.
        if current_hash:
            write_stored_localization_hash(current_hash)
            print(f"  Recorded strings hash {current_hash[:12]} for the next run.")
    print()

    print(f"[release 2/6] Selecting and attaching latest VALID build...")
    select_and_attach_build(
        client, app_id, version.id, version_string,
        current_build_id=version.build_id, interactive=args.interactive,
    )
    print()

    print(f"[release 3/6] Setting releaseType=MANUAL...")
    set_version_release_type(client, version.id, "MANUAL")
    print(f"  releaseType set to MANUAL")
    print()

    print(f"[release 4/6] Staging v{version_string} on a review submission...")
    submission_id = prepare_review_submission(client, app_id, version.id)
    print(f"  v{version_string} is now READY FOR REVIEW (submission {submission_id}).")
    print("  Nothing has been sent to Apple yet.")
    print()

    print(f"[release 5/6] Fully submit v{version_string} for review?")
    if confirm(f"Submit v{version_string} to Apple for review now?"):
        confirm_review_submission(client, submission_id)
        print(f"  Submitted v{version_string} for review.")
    else:
        print(
            f"  Left v{version_string} in READY FOR REVIEW. "
            "Submit it from App Store Connect when you're ready."
        )
    print()

    # Tag last of all: the release is now fully prepared (and maybe submitted),
    # so the tag marks a meaningful, finished state rather than a mid-flight one.
    print(f"[release 6/6] Tagging git as {version_string}...")
    tag_release(version_string)


if __name__ == "__main__":
    main()
