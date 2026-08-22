//
//  StorageUsageBreakdown.swift
//  EncameraCore
//
//  The value type the Storage Insights screen renders. See
//  `Documentation/storage-accounting-model.md` for the decisions behind it.
//

import Foundation

/// How many bytes Encamera occupies, split by where the bytes are and whether the
/// user can get them back.
///
/// The four device buckets are disjoint — no byte is counted twice — so they sum to
/// `totalDeviceBytes`.
///
/// `cloudBytes` is a *different location*, not a fifth bucket, and it **overlaps**
/// `cachedCloudBytes` by design: a downloaded blob occupies both CloudKit and this
/// device's disk, and is counted once in each. The two are therefore never summed.
/// When every blob is cached, `cachedCloudBytes == cloudBytes`; adding them would
/// double the reported figure.
public struct StorageUsageBreakdown: Sendable, Equatable {

    /// Encrypted media in `.local` albums. Irreplaceable — this is the only copy.
    public let localMediaBytes: Int64
    /// The CloudKit blob cache. Re-fetchable ciphertext.
    public let cachedCloudBytes: Int64
    /// Preview thumbnails. Regenerable from the media they preview.
    public let thumbnailBytes: Int64
    /// Per-album media indexes. Derived, and small.
    public let indexBytes: Int64
    /// Total size of media in the user's private CloudKit database, cached here or
    /// not. `nil` means "not knowable right now" — no iCloud account, or no sidecar
    /// data yet — which is a different statement from zero.
    public let cloudBytes: Int64?
    /// How many legacy iCloud Drive albums exist. Their bytes are excluded from every
    /// bucket (see the accounting model); a non-zero count is what makes the screen
    /// say so instead of silently under-reporting.
    public let legacyICloudDriveAlbumCount: Int

    /// Negative inputs are clamped to zero: a negative byte count is a measurement
    /// bug, and propagating one renders a nonsensical ring instead of surfacing it.
    public init(
        localMediaBytes: Int64 = 0,
        cachedCloudBytes: Int64 = 0,
        thumbnailBytes: Int64 = 0,
        indexBytes: Int64 = 0,
        cloudBytes: Int64? = nil,
        legacyICloudDriveAlbumCount: Int = 0
    ) {
        self.localMediaBytes = max(0, localMediaBytes)
        self.cachedCloudBytes = max(0, cachedCloudBytes)
        self.thumbnailBytes = max(0, thumbnailBytes)
        self.indexBytes = max(0, indexBytes)
        self.cloudBytes = cloudBytes.map { max(0, $0) }
        self.legacyICloudDriveAlbumCount = max(0, legacyICloudDriveAlbumCount)
    }

    /// Everything Encamera occupies on this device's disk. Excludes `cloudBytes`,
    /// which is not on this device.
    public var totalDeviceBytes: Int64 {
        localMediaBytes + cachedCloudBytes + thumbnailBytes + indexBytes
    }

    /// The bytes the user can free without losing anything: re-fetchable cache plus
    /// regenerable thumbnails and indexes.
    ///
    /// Never includes `localMediaBytes`. "Free up space" is wired to this number, so
    /// the moment local media leaks in, the button starts deleting photos.
    /// Invariant: `0 <= reclaimableBytes <= totalDeviceBytes`, which holds because
    /// these terms are a subset of that sum.
    public var reclaimableBytes: Int64 {
        cachedCloudBytes + thumbnailBytes + indexBytes
    }

    /// True when there is nothing on disk to show — the screen renders its empty
    /// state rather than a ring of zero-width slices.
    public var isEmpty: Bool {
        totalDeviceBytes == 0
    }
}
