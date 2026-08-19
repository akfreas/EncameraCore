# CloudKit storage plane

This directory is Encamera's **CloudKit storage backend** — the cloud plane that replaces iCloud Drive. It stores each media item as a single CloudKit record (`EncMedia`) in the user's **private** database, carrying the encrypted index fields plus two `CKAsset`s: a small eager **thumbnail** and the full **blob**. Alongside those, one `EncAlbum` record per album makes "which albums exist" a cross-device fact rather than a per-device one.

> **Privacy invariant:** only ciphertext ever reaches CloudKit. The album name is reduced to a non-reversible keyed hash (`albumID`); the two assets are the existing ENC2 encrypted files. No plaintext name, location, or content leaves the device. CloudKit changes the *transport*, never the crypto. See `plans/cloudkit-migration/00-overview.md`.

This is **Option A** from the design decision: one `CKRecord` per media item carrying both metadata and the blob, rather than a separate blob-transport plane.

## How it fits together

```
                 CloudKitFileAccess          ← FileAccess branch for `.cloudKit` albums
                 (encrypt → upload,            (reuses SecretFileHandlerV2 + DiskFileAccess preview)
                  lazy fetch → decrypt)
                        │
                        ▼
              CloudKitSyncCoordinator         ← per-album orchestration (an actor)
              (delta sync → MediaIndexStore,    dedups fetches, applies remote
               blob residency, deletes)         deletes, single-flight sync
                  │                  │
                  ▼                  ▼
        CloudKitBlobCache     CloudKitMediaStoring  ← the protocol seam everything depends on
        (evictable local       │
         ciphertext cache)     ├── CloudKitMediaStore         (production)
                               │      └── CloudKitDatabaseAdapter → CKDatabaseAdapter (real CKOperations)
                               └── InMemoryCloudKitMediaStore  (tests / -CloudKitMockMode)
                        │
                        ▼
                 CloudKitContainer             ← account gating + idempotent zone bootstrap
                 CloudKitSchema                ← the one place record/field/zone names live
```

Three groups of helpers sit beside that stack:

- **Album existence.** `CloudKitAlbumReconciler` reconciles the `EncAlbum` records three ways (apply the deletions the zone change feed reports; pull a remote album into a local discovery marker; push a local CloudKit album whose record never made it to the server), `CloudKitAlbumPublishRegistry` remembers which albums the server has confirmed so an absent record can be read correctly, and `CloudKitAlbumDeleteQueue` keeps a delete intent durable until the server confirms it.
- **Fan-out.** `CloudKitCoordinatorRegistry` hands out one coordinator per album id so the active album and the push fan-out share in-memory state, and `CloudKitAlbumsSync` observes the `cloudKitZoneChanged` notification and reconciles *every* CloudKit album on a push (inactive albums included).
- **Getting media in and out.** `CloudKitMigrationManager` + `CloudKitMigrationPlan` move an album's files from local storage into CloudKit as a resumable, crash-safe pipeline, and `CloudKitFileAccess.exportCiphertext` is the download half of the reverse move. That whole story — both directions, the checkpoint, the UI, the background resume — is in **`MIGRATION.md`**.

## The layers (bottom → top)

| File | Role |
|---|---|
| `CloudKitSchema.swift` | Single source of truth for the container id, zone name `EncameraZone`, the `EncMedia` and `EncAlbum` record types, every field name, and `currentSchemaVersion`. Every other file imports these literals. Debug and Release share one container; isolation comes from the CloudKit **environment** (Development vs Production), not the container id. |
| `CloudKitContainer.swift` | Provisioning only: account-status gating (stays local-only unless `.available`), idempotent custom-zone creation, and the full-zone delete the erase flow uses. Injectable `AccountStatusProviding` / `RecordZoneProvisioning` seams keep tests off the network. No media I/O. |
| `CloudKitMediaStoreError.swift` | The typed error model + `mapCKError` translator that turns raw `CKError`s into actionable cases (`quotaExceeded`, `retry(after:)`, `partial`, `conflict`, `zoneNotFound`, `changeTokenExpired`, …). Pure, unit-testable. |
| `DeviceIdentity.swift` | Stable per-install id written to `creationDeviceID`, used to tell "I authored this" (keep local) from "fetch on tap". |
| `CloudKitDatabaseAdapter.swift` | Narrow database-operation protocol + the production `CKDatabaseAdapter` that wraps each call as a `CKOperation` (save/delete/fetch/query/zone-changes/subscription/cancel). Keeps the store free of `CKOperation` wiring; trivially fakeable. Deliberately exposes **no** long-lived-operation surface — re-enqueueing one raises an uncatchable `NSException` (ENC-133). |
| `CloudKitMediaStoring.swift` | **The protocol seam.** The value types (`CloudKitMediaUpload`, `CloudKitMediaMetadata`, `CloudKitMediaRef`, `CloudKitAlbumUpload`, `CloudKitChangeSet`) and the interface every downstream layer depends on — never CloudKit directly. |
| `CloudKitMediaStore.swift` | Concrete Option-A store: builds one `EncMedia` record (index fields + thumbnail + blob), uploads with progress, cheap asset-free metadata sync (`desiredKeys`), lazy blob/thumbnail fetch, hard delete, change-token delta sync (carrying both record types), push subscription, and the `EncAlbum` save/fetch/delete calls. An interrupted upload is re-driven by the caller's checkpoint, not by a CloudKit long-lived op. State lives in app-group defaults. |
| `InMemoryCloudKitMediaStore.swift` | Deterministic in-memory `CloudKitMediaStoring` for UI tests and offline verification. Never touches the network or an account. |
| `CloudKitBlobCache.swift` | The app-controlled, **evictable** local ciphertext cache (Caches dir, excluded from backup, LRU byte cap). Change-tag-aware: a remote re-upload invalidates the stale copy. One shared instance owns the on-disk index; a just-stored blob is protected from its own store's cap eviction. |
| `CloudKitSyncCoordinator.swift` | Per-album actor that orchestrates everything: single-flight delta sync into the existing `MediaIndexStore`, dedup of concurrent blob fetches, deletes (issued as one server op, retried from a durable queue, and applied in reverse from the change feed), a reap pass on any from-scratch sync, Live Photo two-component merge, and zone-subscription registration (retried on every sync, so a store invalidation heals). |
| `CloudKitFileAccess.swift` | The `FileAccess` branch for `.cloudKit` albums. Save = encrypt (`SecretFileHandlerV2`) then upload; load = lazy fetch then decrypt (with the **format-agnostic** `SecretFileHandler`, see below); enumeration comes from the synced index (never the network); delete = remove the record and clean up every local trace of it; `exportCiphertext` materializes and verifies every blob locally for the CloudKit → local move. Reuses the existing preview pipeline. |
| `CloudKitAlbumReconciler.swift` | Reconciles album *existence* against the `EncAlbum` records: apply the change feed's album deletions (its own change-token cursor, in the namespace the per-album media cursors leave free), pull remote albums into local discovery markers, and self-heal a local CloudKit album whose record never reached the server. Reports how many remote albums could not be materialized for lack of a synced key. |
| `CloudKitAlbumDeleteQueue.swift` | Durable record of album deletes the server has not confirmed. Enqueued *before* the delete is issued, drained by the reconciler, and used to stop the pull path resurrecting an album on the very device that deleted it. `CloudKitMediaDeleteQueue` is the same shape for media, drained at the top of each sync. |
| `CloudKitCoordinatorRegistry.swift` | One coordinator per album id, shared between the active album and the push fan-out. |
| `CloudKitAlbumsSync.swift` | App-level push fan-out: on `cloudKitZoneChanged`, reconcile album existence and every CloudKit album's media index. Single-flight, with a mid-run push honored by one extra pass. |
| `CloudKitMigrationPlan.swift` | The durable checkpoint for a local → CloudKit move: the per-item state machine, the plan's progress maths, and the encrypted atomic plan store. See `MIGRATION.md`. |
| `CloudKitMigrationManager.swift` | The migration engine: plan, run, checkpoint after every transition, pause/cancel/resume, and the process-wide "which albums have a move running" claim. See `MIGRATION.md`. |
| `CloudKitFlightCheck.swift` | A manual, end-to-end smoke test (13 ordered steps) that runs the *real* code paths with dummy data against a signed device — entitlement → account → zone → subscription → encrypt+upload → sync → **cold-cache** server download → thumbnail → cancel/restart → delete. Drives the `ICloudFlightCheckView` workbench behind the `iCloudFlightCheck` toggle. |

## Key invariants & design choices

- **Lazy blob, eager thumbnail.** Metadata sync and the gallery never request `encBlob` — only `desiredKeys` it excludes. The full blob is fetched on tap by a second op; the thumbnail is small enough to fetch eagerly so non-authoring devices render the grid before downloading full-res.
- **Custom zone is mandatory.** `EncameraZone` exists so `CKFetchRecordZoneChangesOperation` delta sync works (Apple's private-DB sync pattern). Bootstrap is idempotent and the "created" flag is keyed by container.
- **Media records hang off their album record.** Every `EncMedia` carries a reference to its `EncAlbum` parent with `.deleteSelf`, so deleting an album cascades. CloudKit rejects a save whose parent isn't already on the server, so anything creating media must make sure the album record exists first.
- **Change tokens are per-album.** The zone is shared across albums, but each album keeps its own cursor so syncing one album doesn't advance the others'. The store fetches purely; the coordinator commits the token **only after** the index is durably saved, so a mid-sync failure re-fetches rather than loses data.
- **Live Photos = two records, one entry.** A photo and video component share a `mediaID` but use distinct record names (`mediaID#type`). The coordinator merges them into one `MediaIndexEntry`.
- **A delete is one server op.** Deleting media deletes its record, which takes both assets with it atomically; deleting an album deletes the `EncAlbum` record, and every `EncMedia` parented to it with `.deleteSelf` cascades away with its blobs. There is no soft-delete state to propagate, purge, or leak. A delete that lands mid-fetch still wins locally — the fetched copy is discarded — because that guard is local bookkeeping, not a server field.
- **Deletions travel on the change feed.** `CKFetchRecordZoneChangesOperation` is what reports a record's removal, and it carries the deleted record's *type*, so one feed serves both media and albums. Absence from the `EncAlbum` `CKQuery` is never a delete signal: that index is eventually consistent, so "deleted" and "not indexed yet" look identical. `CloudKitAlbumPublishRegistry` breaks the tie from local state — an album the server never confirmed is pushed (self-heal), one it confirmed before and no longer has was deleted elsewhere. A from-scratch sync also reaps anything the index still holds that the full fetch did not return, which covers deletions that happened while the change token was expired.
- **Legacy tombstones are still honored.** `deletedAt` exists on both record types and is READ, never written. Zones written by earlier builds still hold records carrying it; those reads keep deleted media and albums from resurrecting, and they queue a real delete so the record is finally reclaimed and the zone heals itself.
- **A delete intent outlives the app.** Both delete queues are app-group defaults, written *before* the server call, so a delete made offline or interrupted by termination is retried on a later sync instead of leaking a record and its blob forever. Until an album's delete is confirmed, that album is not re-materialized locally.
- **Account-absent ⇒ local-only.** Anything short of `.available` means the app stays on its local plane; CloudKit calls no-op rather than crash.
- **Reads must be format-agnostic.** A migrated album can hold V1-format blobs, because the migration uploads the on-disk ciphertext verbatim. Reads use `SecretFileHandler` (which sniffs the format); `SecretFileHandlerV2` throws on V1 and is write-side only. See ENC-135.
- **Existing iCloud Drive albums stay readable.** iCloud Drive is a dead end as a *destination* — unconditionally, not gated on the CloudKit flag — but albums already there keep working until the user moves them. Those two questions are `isStorageTypeOfferedForNewAlbums` and `isStorageTypeAvailable`, and they are deliberately separate.

## Tests

- **Unit tests** (XCTest) mock at the `CloudKitMediaStoring` / `CloudKitDatabaseAdapter` seams, so CI never touches the network or an iCloud account.
- **UI tests** run offline against `InMemoryCloudKitMediaStore` via `-CloudKitMockMode`.
- **Device suites** (`UITests/CloudKit*DeviceTests.swift`) need a signed device and a real iCloud account, and are run by hand — including a two-device migration suite and a Production-environment run that catches an undeployed schema. See the testing section of `MIGRATION.md`.
- **`CloudKitFlightCheck`** is the *only* interactive path that hits a live container from inside the app, and it is manual (a human runs it on a signed device from the debug workbench).

## Where to start reading

1. `CloudKitSchema.swift` — the vocabulary (records, fields, zone).
2. `CloudKitMediaStoring.swift` — the contract every layer is written against.
3. `CloudKitSyncCoordinator.swift` — the orchestration and the hard-won invariants.
4. `CloudKitFileAccess.swift` — how the app actually saves/loads/deletes media.
5. `MIGRATION.md` — how an album gets into CloudKit in the first place, and how it comes back.

Design rationale and the chunk-by-chunk build live in `plans/cloudkit-migration/` (start with `00-overview.md`).
