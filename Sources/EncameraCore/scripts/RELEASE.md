# release.py

Release driver for the iOS app. Runs three preflight gates against App Store Connect and the local repo, then walks the manual ASC steps (localize → tag → attach build → set release type → submit).

```bash
python release.py [--credentials PATH] [--skip-preflights] [--dry-run]
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
| 1 | `git rev-parse --abbrev-ref HEAD` equals `main` | Releases must be cut from main. Merge your branch and switch to main, then re-run. |
| 2 | `git diff --quiet` and `git diff --cached --quiet` both pass (no staged or unstaged changes to tracked files; untracked files are tolerated) | The working tree is dirty. Commit or stash your changes — the release tag must capture exactly what's on HEAD. |
| 3 | `git diff <last_tag> -- app_store.yml` produces non-empty output | "What's new" wasn't updated. Edit `scripts/app_store_localization/app_store.yml`, commit, and re-run. |
| 4 | Every `.lproj` directory has every key from `en.lproj/Localizable.strings` | Strings have drifted. Run `scripts/string_diff.py` to translate the missing keys, commit, then re-run. |
| 5 | No TestFlight builds for the release version are in `processingState=PROCESSING` | A build is still being processed by Apple. Wait for it to finish (poll TestFlight or `expire_testflight_builds.py --dry-run` to inspect), then re-run. |

`--skip-preflights` bypasses all three. Use sparingly — these gates exist to catch the exact mistakes that have shipped broken releases in the past.

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

## Related

- `app_store_localization/localize.py` — `Localizer` class invoked by step 1.
- `string_diff.py` — translates missing keys; preflight 2 leans on `get_localization_status` from this script.
- `asc/` — App Store Connect API client. The release-relevant helpers (`find_editable_version`, `set_version_release_type`, `list_builds_for_version`, `set_build_for_version`, `submit_for_review`) live in `asc.releases` and `asc.testflight`. See `asc/AGENTS.md` before adding new ASC functionality here.
- `expire_testflight_builds.py` — sibling script; same credential autodetect pattern.
