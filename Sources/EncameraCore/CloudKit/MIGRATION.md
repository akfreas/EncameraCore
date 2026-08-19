# Moving an album between this device and CloudKit

This is the story of a storage move, start to finish, in both directions. `README.md` describes the CloudKit storage plane itself — how media is stored and synced once an album already lives there. This file describes how an album *gets* there, and how it comes back.

Design rationale and the chunk-by-chunk build live in `plans/cloudkit-migration/12-local-to-cloudkit-migration.md`. Where the plan and the code disagree, the code wins.

## Why a move is not a file move

Every other storage move in the app is a directory rename: the files are already on disk, so moving them is one atomic-ish operation that either works or doesn't. A CloudKit move is not that. It uploads every file over the network, one at a time, and then deletes the local original — so it takes minutes, it can be interrupted at any point, and half of it can succeed.

Two consequences drive the whole design:

1. **The move has to survive being interrupted.** The app can be killed, the phone can run out of battery, the network can drop. So the engine writes an encrypted checkpoint to disk after *every* single state change, and that checkpoint — not anything CloudKit remembers — is the source of truth for where the move got to.
2. **A local original is never deleted until its copy is confirmed present in CloudKit.** Upload, then verify by fetching the record back, then delete. If verification fails for any reason, the local file stays and the item is retried.

Because of this, `AlbumManager.moveAlbum(album:toStorage:)` — the ordinary synchronous move — *refuses* both CloudKit directions. Asking it to move something to CloudKit throws `migrationRequiredForCloudKit`; asking it to move a CloudKit album anywhere throws `downloadRequiredFromCloudKit`. Every caller has to go through the paths below.

## The two directions at a glance

| | local → CloudKit | CloudKit → local |
|---|---|---|
| Driven by | `CloudKitMigrationManager` (an engine with a durable plan) | `AlbumManager.moveCloudKitAlbumToLocal` (one pass, no checkpoint) |
| Resumable after a kill? | Yes — from the on-disk checkpoint | No — it restarts from the beginning, which is safe because nothing is destroyed until the end |
| Runs in the background? | Yes — launch-time resume plus a background processing task | No — it only runs while the app is in the foreground |
| Order of operations | upload → verify → delete local original, per item | download everything → verify every copy → *then* remove the cloud copies |
| Point of no return | Per item, at the local delete | Once, after every local copy is verified |
| Cancelling | Safe at any time; leaves a resumable half-moved album | Safe until the export finishes; after that the cancel is ignored |

Both directions report through the same UI: the blocking overlay on the album screen, the floating progress pill, and the same `MigrationProgress` snapshot type.

## Where the pieces live

The engine and its checkpoint live in `EncameraCore` (this directory). Everything that drives it, shows it, or resumes it lives in the app target, because it needs SwiftUI, `BackgroundTasks`, and the shared background-task UI.

| File | What it does |
|---|---|
| `CloudKitMigrationPlan.swift` | The checkpoint: `MigrationItem` (one file's state machine), `MigrationPlan` (the whole album's work list plus progress maths), and `MigrationPlanStore` (encrypted, atomic read/write of the plan file). |
| `CloudKitMigrationManager.swift` | The engine. Plans the work, runs it item by item, checkpoints after every transition, handles pause/cancel/resume, and publishes `state` + `progress`. Also owns the process-wide "which albums have a move running" set. |
| `Encamera/AlbumManagement/CloudKitMigrationLauncher.swift` | Bridges the headless engine to the app: builds the pre-flight estimate, registers a `MigrationTask` in the shared background-task UI, pumps engine progress into it, and runs the reverse direction through the same surfaces. |
| `Encamera/AlbumManagement/CloudKitMigrationRunRegistry.swift` | Keeps each launcher alive for exactly as long as its run, keyed by album id. Without it, popping the album screen mid-move deallocates the launcher and the progress UI freezes. |
| `Encamera/AlbumManagement/CloudKitMigrationResumer.swift` | Finds interrupted checkpoints and drives each one to completion. Called at launch and from the background task. |
| `Encamera/AlbumManagement/CloudKitMigrationBackgroundTask.swift` | The `com.encamera.cloudkit-migration` background processing task — best-effort extra progress while the app is backgrounded. |
| `Encamera/AlbumManagement/MigrationStatusOverlay.swift` | The blocking, non-dismissible status view over the album grid, with phase, counts, ETA and Cancel. |
| `Encamera/AlbumManagement/PartialMigrationBanner.swift` | The persistent banner on an album whose move was stopped part-way, with Resume. |
| `Encamera/AlbumManagement/AlbumDetailView.swift` | The screen that starts both directions, binds the launcher, and decides when the overlay and banner are shown. |

Supporting pieces used by the move but owned elsewhere: `AlbumManager.finalizeMigrationToCloudKit` (the album flip), `AlbumManager.moveCloudKitAlbumToLocal` (the reverse move), `CloudKitFileAccess.exportCiphertext` (the download half of the reverse move), and `Album.cloudKitTwin` / `Album.removeDrainedSourceDirectory`.

---

# Direction 1: local → CloudKit

## What the user sees

1. On the album screen the user picks **iCloud** as the storage type and taps **Confirm Storage**.
2. The app shows a warning alert with an item count and a rough time estimate ("this may take over an hour"). Building that estimate does *not* write anything to disk, so backing out here leaves no trace.
3. On confirm, a full-screen overlay covers the album grid for the whole move. It shows a percentage ring, what the move is currently doing ("Uploading", "Verifying", "Removing local copy"), an "N of M" count, the total size, an ETA, and a **Cancel** button.
4. The grid is covered on purpose: mid-move the album is genuinely half-drained — some files have already had their local copies deleted — and showing that is more confusing than showing nothing.
5. If the user leaves the screen, the move keeps running and the floating progress pill takes over. Coming back to the album screen re-attaches the overlay to the same run.
6. When it finishes, the album flips to CloudKit and the screen adopts the new album.

Only `.local` albums are offered this. iCloud Drive albums are deliberately refused — see [iCloud Drive is not a migration source](#icloud-drive-is-not-a-migration-source).

## The checkpoint file

One file per album, at:

```
~/Library/Application Support/CloudKitMigration/<sha256(album.id)>.encplan
```

It is encrypted with the album's own key (the same encryption `MediaIndexStore` uses), written atomically, and excluded from backup. The filename is a hash, so the album's name never appears on disk in the clear.

The plan holds the album name, the source storage type, when it was created, an optional `cancelledAt` stamp, and the list of work items. Each item is one media *component* — a Live Photo contributes two, because a Live Photo is two CloudKit records — and carries the media id, the CloudKit record name, the file size, the current state, and the last error if any.

Two things about the file matter more than they look:

- **It is written after every state transition, not periodically.** That is what makes "resume exactly where it left off" true rather than approximate.
- **Its existence means unfinished business.** A completed migration deletes it. So any surviving plan file means either the move is half-done, or the move finished uploading but the final album flip failed and needs retrying.

## One item's journey

Each item walks a small state machine, and it can only advance one step per checkpoint write:

```
pending → uploading → uploaded → verified → sourceDeleted    ← done

pending → skipped        source ciphertext is missing        ← done, terminal
  any   → failed         retryable; restarts as pending on the next run
```

What each step actually does:

- **pending → uploading.** The engine checks that the encrypted source file is still on disk. If it isn't, the item is marked `skipped` — terminally. A stale index entry pointing at a file that no longer exists must never wedge the whole album short of completion.
- **uploading.** The existing ciphertext is uploaded as-is. Nothing is re-encrypted; the bytes that were on disk are the bytes that go to CloudKit. The upload goes through the same `CloudKitSyncCoordinator.upload` the live app uses, so the migrated album's index and blob cache end up exactly as a fresh save would leave them. CloudKit's "retry after N seconds" is honoured up to three times per item, and while waiting the UI shows "Retrying".
- **uploading → uploaded.** If the upload comes back with a *conflict* — a record with that name is already on the server, e.g. from an earlier run whose checkpoint was lost — that is not an error. The bytes are there; the engine falls through to verification rather than fighting the conflict.
- **uploaded → verified.** The record is fetched back by record id (a strongly-consistent read, not the eventually-consistent query) and its size is compared against the local file. Anything short of "present with the right size" fails the item, and the local original is left alone.
- **verified → sourceDeleted.** The local encrypted file is deleted. This is the only irreversible step, so two guards sit in front of it: a cancel requested mid-item stops here rather than deleting, and an item that entered this run *already* `verified` (from an earlier run) is re-verified first — that old verification could be arbitrarily stale, since the record may have been deleted from another device since.

The preview thumbnail is **not** deleted along with the original. Previews live in a global, storage-agnostic thumbnail directory that the migrated CloudKit album reads from the same path, so deleting them would force a re-download of every thumbnail — and for a Live Photo would strip the shared preview before its second component uploads.

## Planning and re-planning

`plan(album:)` enumerates every encrypted component in the album, gives each one a stable media id and a deterministic CloudKit record name, and merges that fresh list into whatever plan already exists on disk.

The merge rules are what make a resume safe:

- Items that already made progress (`uploading`, `uploaded`, `verified`, `sourceDeleted`, `skipped`) keep their state.
- Items that were `pending` or `failed` restart as `pending` with a freshly-read file size.
- Items in the old plan that enumeration can no longer see are **kept** if they made progress, and dropped if they didn't. A `sourceDeleted` item has no source file left to enumerate — dropping it would let the album finalize as if that item had never existed.

Because record names are derived from the media id rather than allocated, re-planning never produces a duplicate upload.

## Finishing: the album flip

When no item has work left, `AlbumManager.finalizeMigrationToCloudKit` flips the album's *identity* — the bytes are already in CloudKit and in the on-device blob cache:

1. Write the CloudKit discovery marker (a directory named after the album's encrypted name). This marker is the **only** way this device finds a CloudKit album, so if writing it fails the whole finalize fails.
2. Push the `EncAlbum` record so the album shows up on the user's other devices.
3. Remove the drained source directory — but only if it contains no regular files. A file the plan never enumerated is left in place rather than destroyed, which means the album simply stays visible in its old storage instead of losing data.
4. Delete the now-stale source index and the checkpoint file, and broadcast the change so the grid refreshes.

If step 1 or 2 throws, the checkpoint is deliberately **kept**. The album's bytes are safe in CloudKit but unreachable on this device without the marker, so the next resume retries the finalize. This is why "a plan with no remaining item work" is still treated as pending work.

There is one exception. A plan with zero items for an album whose CloudKit marker already exists is not an empty album — it is a re-run against an album that already finished. That plan is deleted without re-finalizing.

## Stopping: cancel, pause, and failure

These are three different things and the difference matters.

**Cancel** is a user action, and it is durable. The engine stops at the next safe boundary (never mid-item), reverts any item that was mid-upload back to `pending`, and stamps `cancelledAt` on the plan. The checkpoint is kept so the user can finish the move later, but automatic background resume deliberately skips a cancelled plan — the app must not quietly restart something the user explicitly stopped. Cancel always routes through the background-task manager rather than calling the engine directly, so the floating pill is finalized instead of being orphaned.

**Pause** is the system asking for the app's time back — specifically, a background processing slice expiring. The engine checkpoints at the next item boundary and stops. Nothing is stamped, so the plan stays freely resumable.

**Failure** comes in two flavours. Run-halting failures — iCloud storage full, no iCloud account, the CloudKit production schema never deployed — stop the whole run and surface a blocking alert with a **Resume** affordance; the user fixes the cause and resumes. Everything else fails just that item, records the error on it, and lets the run continue; at the end the run reports "N item(s) failed" including the first item's actual error.

`quotaExceeded`, `accountUnavailable` and friends usually arrive wrapped in a CloudKit *partial failure*, because a save is a `CKModifyRecordsOperation` whose per-record errors are reported that way. `unwrapPartial` unwraps single-record partials so those cases are actually recognised, and unwraps multi-record partials only when every record agrees.

## Resuming

There are three ways an interrupted move gets picked back up:

1. **At launch.** `CloudKitMigrationResumer.resumePending` asks the engine for every album with a non-cancelled checkpoint and drives each one. It does not return until they have actually finished, because the background task handler awaits it before reporting its slice complete.
2. **In the background.** A `BGProcessingTask` (`com.encamera.cloudkit-migration`) requests processing time. Scheduling is gated on work actually existing — a slice is requested when a move starts or when a checkpoint is found at unlock, and the handler only re-arms while a checkpoint remains. Waking the app forever for users who never migrate would burn the background budget iOS uses to decide whether to grant a slice when a real move needs one. This is *best effort*; correctness comes from the checkpoint and launch-time resume. Long-lived CloudKit operations, which used to continue while suspended, were removed in ENC-133 because they crashed the app on the next launch.
3. **From the banner.** An album with a stopped, partly-finished move shows a persistent banner on its screen with the counts and a Resume button. This is the only surface that mentions a user-cancelled move, since auto-resume skips it. It replaced a one-shot alert that could be dismissed into oblivion.

## Rules that must not break

- **Only one run per album per process.** `CloudKitMigrationManager` keeps a static set of album ids with a run in flight. `start` claims it atomically (no `await` between the check and the insert), and a second `start` for the same album returns `false` without changing any state. Two runs against one plan would clobber the checkpoint and double-upload or double-delete. The reverse direction claims the same set via `claimExternalRun`, so the two directions can never fight over one album.
- **Never publish a terminal state from planning.** A resume whose only remaining work is a retried finalize would otherwise report `.completed` before the run even starts, tearing the UI binding down early and swallowing a second finalize failure. Terminal states belong to `run()`.
- **Progress goes through one funnel.** `run()` rebuilds the progress snapshot before and after every item, so a phase written directly into `progress` gets clobbered on the next loop turn. The phase lives on the manager and every publish goes through `publishProgress`. A phase that is only recorded and not published is invisible until the next item boundary, by which point it is already stale — so `setPhase` does both.
- **A phase is what marks a run as live.** `progress` is a non-optional published value that starts empty, so merely subscribing replays that empty snapshot. The overlay therefore requires a phase, not just a snapshot — otherwise it appears over "0 of 0" before planning has finished.
- **Fail closed if the album id hash cannot be derived.** `album.id` embeds the cleartext album name, so any fallback would put plaintext on the server, in a namespace the reconciler could never match.
- **The album record must exist before any media uploads.** Every `EncMedia` record references its `EncAlbum` parent, and CloudKit rejects a save whose parent isn't on the server yet. The engine saves the album record itself (idempotently) rather than waiting for the reconciler to get there on its own schedule.
- **Use the shared blob cache, not a fresh instance.** Separate instances write the cache index from divergent snapshots and clobber each other, and a private cache would leave the shared one ignorant of the migrated blobs — breaking the "the blob is in the on-device cache" claim that makes the local delete safe.

---

# Direction 2: CloudKit → local

This one runs in a single pass with no checkpoint, and it can afford to: nothing is destroyed until everything has been safely downloaded, so an interrupted run just means the work is repeated.

`AlbumManager.moveCloudKitAlbumToLocal` does it in this order:

1. **Reconcile the index first.** A record another device uploaded moments ago has to be included, or it would be left orphaned in the cloud. A *failed* reconcile aborts the whole move — every destructive step below enumerates from the local index, so a stale or empty index (fresh device, transient error) would export nothing and still delete the album.
2. **Export every ciphertext** via `CloudKitFileAccess.exportCiphertext`, downloading anything not resident in the blob cache. Each copy is verified by size before it counts. Previews aren't copied — they already live in the shared thumbnail directory.
3. **The point of no return.** A cancellation is checked here. Before this line, cancelling is free: the local copies are just redundant bytes and the album is still whole in CloudKit. After it, the cloud plane is coming down and aborting would leave the album half-deleted in the zone while it still reads as CloudKit on this device.
4. **Remove the cloud plane.** Delete every media record, then delete the album record. Both are real deletes, so the blobs are reclaimed and the record names are free again — which is what makes a later move *back* into iCloud an ordinary insert rather than a collision with something the server still holds. The album delete is *awaited* rather than fire-and-forget: the retry queue is device-local, so relying on it here would let a fresh install rematerialize the album before this device got around to retrying. If it still fails, it stays queued (and the album's published marker is left alone) so the reconciler retries — the worst interim state on another device is an empty album, never lost data.
5. **Drop the CloudKit identity locally**: the discovery marker, the blob cache directory, and both stale indexes. The disk scan rebuilds the local index from the exported files.

The launcher runs this through the same surfaces as the forward direction, which is why the same overlay appears: it claims the engine's active set, registers a `MigrationTask` with `direction: .toLocal` so the pill says "Moved to this device", and maps the reverse move's progress onto the same `MigrationProgress` type via the same pump. The overlay's Cancel button becomes inert once the phase reaches "removing remote copy" — that is step 4, past the point of no return.

Failures here surface as the move-failed alert, deliberately *not* as the blocking migration failure — that one's Resume button resumes the forward engine.

---

# What both directions share

**The overlay** (`MigrationStatusOverlay`) is shown when three things are true at once: the feature is enabled, the engine's active set contains this album, and there is a progress snapshot carrying a phase. Any one alone is wrong — the active set is true during the pre-run planning window when there's nothing to show, and a snapshot could outlive a run that already ended.

**The floating pill** and the overlay are mutually exclusive (`shouldShowFloatingPill`): one run must never be reported twice on the same screen.

**The registry** is what lets a screen bind to a run it didn't start. The album screen subscribes to the registry's published launchers and re-binds whenever the launcher for its album changes — which is how an auto-resumed migration, started by the resumer before the screen existed, still drives that screen's overlay.

**Erase** interacts with both. `EraserUtils` calls `requestAbortAll()` first, which makes every in-flight run halt at its next item boundary *without* writing another checkpoint (the wipe removes them all) and refuses new starts. It then clears every plan file, cancels any pending background task request, and — for a full erase — deletes the CloudKit zone. If deleting the user's cloud data fails while they plausibly have some, a marker is persisted so the app can warn them later.

---

# Testing

Nothing in the automated suites touches a live CloudKit container.

**Unit tests** (`EncameraCoreTests/CloudKit/`, `Tests/`) mock at the `CloudKitMediaStoring` seam:

- `CloudKitMigrationManagerTests` — the engine: durable cancel, resume from every item state, missing-source `skipped`, stale-verification recovery, partial-failure unwrapping, finalize-failure keeping the checkpoint, empty-album completion.
- `CloudKitMigrationPlanTests` — the plan's progress maths, merge rules, and the encrypted store's round-trip and failure modes.
- `CloudKitMigrationResumerTests`, `CloudKitMigrationRunRegistryTests`, `CloudKitMigrationBackgroundSchedulingTests` — resume, launcher lifetime, and when a background slice is requested and re-armed.
- `AlbumDetailMigrationBindingTests`, `AlbumDetailMoveFailureTests` — the overlay/banner/pill predicates and the move-failed alert routing.

**UI tests** run offline against `InMemoryCloudKitMediaStore` via `-CloudKitMockMode`. `CloudKitMigrationUITests` covers migrate → cancel → banner → resume. `-CloudKitUploadDelayMs` and `-CloudKitDownloadDelayMs` slow the run just enough for the overlay to be observable.

**Device suites** need a signed device and a real iCloud account, and are run by hand:

- `CloudKitDeviceSuiteTests` — flight check, native CloudKit albums, delete propagation.
- `CloudKitMigrationProgressDeviceTests`, `CloudKitMigrationDurabilityDeviceTests` — progress/cancel/banner/resume, and checkpoint survival across a state-preserving relaunch.
- `TwoDeviceCloudKitMigrationDeviceTests` (via `Scripts/two-device-cloudkit-migration-test.sh`) — migrate on one device, verify on the other.
- `CloudKitMigrationProductionWallDeviceTests` (via `Scripts/production-wall-device-test.sh`) — runs against the **Production** CloudKit environment to catch an undeployed schema, which is exactly the failure that never shows up in Development.

The engine reports a machine-readable marker (`UITestMigrationProgress`) with the verified/total counts, the current phase, the engine state, and the count of background slices actually granted — so a device test can tell "iOS never scheduled us" apart from "the migration is stuck".

---

# Things that surprise people

### iCloud Drive is not a migration source

`plan(album:)` refuses anything that isn't `.local`. An iCloud Drive album's files can be evicted, in which case enumeration sees a placeholder but the materialized path doesn't exist — so the engine would mark every evicted item `skipped` and then happily finalize, silently stranding those files in a directory the flipped album no longer surfaces. Until the migration materializes evicted files and verifies them locally first, this direction is not offered. The album screen doesn't route `.icloud` albums into the migration flow at all; they fall through to `moveAlbum`, which throws and shows the move-failed alert.

Separately: iCloud Drive is a dead end as a *destination* — unconditionally, not gated on the CloudKit flag — but existing iCloud Drive albums stay fully readable and writable. Those are two different questions and they have two different functions — `isStorageTypeOfferedForNewAlbums` versus `isStorageTypeAvailable`.

### A cancelled plan is kept, not deleted

Cancelling stops the move but keeps the checkpoint, so any item that already reached CloudKit is recovered when the user resumes rather than being re-uploaded. What the cancel changes is that *automatic* resume skips it.

### "No remaining work" does not mean "finished"

Completion deletes the checkpoint. So a plan on disk with every item `sourceDeleted` means the uploads finished but the album flip didn't — and it must be retried, or the album is safe in CloudKit and reachable nowhere on the device.

### A fresh engine is built for every run

The launcher never reuses a manager. A cached one still holds its previous terminal state, which a new subscription replays immediately — tearing the UI binding down before the resumed run has started.

### Migrated albums can hold V1-format blobs

The migration uploads the on-disk ciphertext verbatim, and a legacy library is full of V1-format files. That is why CloudKit *reads* must use the format-agnostic `SecretFileHandler` and never `SecretFileHandlerV2`, which throws on V1. See ENC-135 and the header of `CloudKitFileAccess.swift`.
