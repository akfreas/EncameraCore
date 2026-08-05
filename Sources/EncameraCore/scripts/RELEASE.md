# release.py

Release driver for the iOS app. Runs nine preflight gates against App Store Connect, Xcode Cloud and the local repo, then walks the manual ASC steps (localize → attach build → set release type → stage for review → submit → tag).

```bash
python release.py [--credentials PATH] [--skip-preflights] [--dry-run] [--interactive] [--force-localize] [--build-timeout MINUTES]
```

## Setup

The script uses the editable `asc` library and the `Localizer` class from `app_store_localization/localize.py`. All dependencies for every script in this directory live in one virtualenv at `scripts/.venv`, built from `scripts/requirements.txt`. Create it once with:

```bash
python3.11 -m venv .venv
.venv/bin/pip install -r requirements.txt
```

Then run the release driver with it:

```bash
source .venv/bin/activate
python release.py --dry-run
# or, without activating:
.venv/bin/python release.py --dry-run
```

The first run should be `--dry-run` — it prints the planned release without touching ASC or git.

Credentials are loaded from the same `credentials.yml` as `localize.py` and `expire_testflight_builds.py`. The autodetect order is:

1. `--credentials PATH`
2. `scripts/app_store_localization/credentials.yml`
3. `scripts/credentials.yml`
4. `./credentials.yml`

## What it does

The script auto-detects the release version by querying ASC for the latest non-live `appStoreVersion` in an editable state (`PREPARE_FOR_SUBMISSION`, `DEVELOPER_REJECTED`, `METADATA_REJECTED`, `REJECTED`, `INVALID_BINARY`, `WAITING_FOR_EXPORT_COMPLIANCE`, `READY_FOR_SUBMISSION`). If no editable version exists, the script bails — create one on App Store Connect first.

### Preflight gates

| # | Check | Failure means |
|---|---|---|
| 1 | `git rev-parse --abbrev-ref HEAD` equals `release` | Releases must be cut from the release branch. Check it out, then re-run. |
| 2 | `git diff --quiet` and `git diff --cached --quiet` both pass (no staged or unstaged changes to tracked files; untracked files are tolerated) | The working tree is dirty. Commit or stash your changes — the release tag must capture exactly what's on HEAD. |
| 3 | Local `release` is at the same commit as `origin/release` (after `git fetch origin release`) | Local has diverged from origin. Push or pull so they match — the tag must point at what's on origin. |
| 4 | `git diff <last_tag> -- app_store.yml` produces non-empty output | "What's new" wasn't updated. Edit `scripts/app_store_localization/app_store.yml`, commit, and re-run. |
| 5 | Every `.lproj` directory has every key from `en.lproj/Localizable.strings` | Strings have drifted. Run `scripts/string_diff.py` to translate the missing keys, commit, then re-run. |
| 6 | `project.yml` `marketing_version` == the editable ASC version == a VALID TestFlight build | The version being released doesn't line up across the repo, ASC and TestFlight. Reconcile them before releasing. |
| 7 | No TestFlight builds for the release version are in `processingState=PROCESSING` | A build is still being processed by Apple. Wait for it to finish (poll TestFlight or `expire_testflight_builds.py --dry-run` to inspect), then re-run. |
| 8 | The "Build for TestFlight" Xcode Cloud workflow has no `PENDING`/`RUNNING` run | A build is mid-flight on the general workflow and whatever it uploads would supersede the build about to be attached. Wait for it, or cancel it. |
| 9 | The build that will ship was produced by the "Build Release for App Store" workflow, from the commit on HEAD | See below — this is the provenance gate, and the only one that offers to fix itself. |

**Gate 9 — provenance.** The build the release attaches is simply the newest `VALID` TestFlight build for the version, and TestFlight cannot tell you where a build came from: one archived off a feature branch by "Build for TestFlight" (which starts from *any* branch) looks identical there. So provenance is checked at the source. "Build Release for App Store" (`ADD12807-AE85-4814-88C2-F580FFE0C39D`) is manual-start with its source pinned to the `release` branch, and the gate requires that its latest run succeeded, that the run archived the exact commit on HEAD, and that the build that run produced *is* the build that will be attached. Together those mean the binary going to Apple was built from this branch, at this commit, by the one workflow that can't build anything else.

The release workflow is deliberately absent from gate 8, because gate 9 owns its state and can do something better than refuse:

- **A run is already building HEAD** — offers to wait for it rather than start a duplicate.
- **Anything else fixable by building HEAD** (the last run failed or was canceled, built an older commit, produced no build, or another workflow's build is newer on TestFlight) — offers to start "Build Release for App Store" on `release` and wait.
- **Not fixable by building** (git can't resolve HEAD) — fails outright.

On "yes" it starts the run, polls until the archive finishes, polls again until Apple has processed the upload into a `VALID` TestFlight build, then **re-runs the provenance check against the new build** and continues the release from there. The offer is not the proof — the re-check is. Ctrl-C during the wait is safe: the cloud build carries on, and re-running the script picks it back up. `--build-timeout` (default 60 minutes, applied to the archive and to processing separately) bounds each wait; `--dry-run` reports the offer it would make and exits non-zero without starting anything.

Xcode Cloud builds a *reference*, not a sha — it archives the tip of `release` at the moment the run starts. Gate 3 has already proven local `release` and `origin/release` are the same commit, so that tip is HEAD, and the post-build re-check confirms it rather than trusting it.

`--skip-preflights` bypasses all nine. Use sparingly — these gates exist to catch the exact mistakes that have shipped broken releases in the past.

### Release steps (run sequentially, fail fast)

1. **Localize** — instantiates `Localizer(app_store.yml, credentials.yml).run()` to push translated metadata to ASC.
2. **Tag** — `git tag <version>` (skipped if the tag already exists locally), then prompts y/N before `git push origin <version>`.
3. **Attach build** — finds the most recently uploaded TestFlight build in `processingState=VALID` for the release version and attaches it to the App Store version via `PATCH /v1/appStoreVersions/{id}` → `relationships.build`.
4. **Set release type** — sets `releaseType=MANUAL` so the version doesn't auto-release after Apple approves it.
5. **Submit for review** — creates the review submission, adds the version as a submission item, and confirms (`submitted: true`).

## --dry-run

Resolves credentials, the editable version, the last tag, and the candidate build, then prints the planned actions. Does not run the localizer, tag, attach the build, change release type, or submit. Use this every time before a real run to confirm the script picked the right version and build.

Example output:

```
=== Dry-run release plan ===
  1. Run Localizer on .../app_store_localization/app_store.yml
  2. git tag 2.7.0 (then prompt to push)
  3. attach latest VALID build:
  Latest VALID build: 833 (uploaded 2026-06-01T05:38:58-07:00, id=...)
  [dry-run] would attach this build to the version
  4. set releaseType=MANUAL on version <id>
  5. submit version <id> for review
```

## Before you run it: `pre-release-smoke.sh`

`release.py` gates on the state of ASC and the repo, not on whether the app works. `pre-release-smoke.sh` is the test gate that belongs before it — it runs every automated suite this repo has on this machine, including the on-device suites that skip themselves everywhere else:

```bash
EncameraCore/Sources/EncameraCore/scripts/pre-release-smoke.sh          # everything
EncameraCore/Sources/EncameraCore/scripts/pre-release-smoke.sh --list   # the phases
EncameraCore/Sources/EncameraCore/scripts/pre-release-smoke.sh --skip-device  # simulator only
```

The console shows only passes and failures (xcpretty); full xcodebuild logs, JUnit reports and `.xcresult` bundles land under the gitignored `build/pre-release-smoke/run-<timestamp>/`. It exits non-zero if any suite fails **or runs zero tests** — a phase that executes nothing is treated as a failure, because that is how a mis-wired scheme and a wholly-skipped device suite both present themselves. Attach the handset (unlocked, Auto-Lock Never) before a full run, or the device phases are reported as unmet.

## Related

- `pre-release-smoke.sh` — run every suite locally before starting a release.
- `app_store_localization/localize.py` — `Localizer` class invoked by step 1.
- `string_diff.py` — translates missing keys; preflight 2 leans on `get_localization_status` from this script.
- `asc/` — App Store Connect API client. The release-relevant helpers (`find_editable_version`, `set_version_release_type`, `list_builds_for_version`, `set_build_for_version`, `submit_for_review`) live in `asc.releases` and `asc.testflight`. See `asc/AGENTS.md` before adding new ASC functionality here.
- `expire_testflight_builds.py` — sibling script; same credential autodetect pattern.
