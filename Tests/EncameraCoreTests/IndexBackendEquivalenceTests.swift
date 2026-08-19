//
//  IndexBackendEquivalenceTests.swift
//  EncameraCoreTests
//
//  The payoff of centralizing the reconcile algebra: the disk and CloudKit
//  backends must build the *same* index shape for the same logical media. Each
//  backend keeps its own source-specific mapping (disk reads file metadata,
//  cloud reads CloudKit component records), but both feed the shared `upsert`
//  algebra — so id grouping and the photo/video component flags must come out
//  identical. This test feeds one logical media set through both mapping → upsert
//  sequences and asserts the structural fields match, guarding the drift the old
//  duplicated logic allowed.
//
//  Dates and `subtypeRawValue` are deliberately NOT compared: they are legitimate
//  source differences (cloud carries no per-item subtype and stamps both dates
//  from the record's `createdAt`), exactly the fields the plan flags as
//  backend-specific.
//

import XCTest
@testable import EncameraCore

final class IndexBackendEquivalenceTests: XCTestCase {

    /// The structural shape the shared algebra is responsible for: which ids
    /// exist and which component flags each carries. Sorted for order-independent
    /// comparison.
    private struct Shape: Equatable, CustomStringConvertible {
        let rows: [String: [Bool]]   // id -> [hasPhoto, hasVideo]
        init(_ entries: [MediaIndexEntry]) {
            rows = Dictionary(uniqueKeysWithValues: entries.map {
                ($0.id, [$0.hasPhotoComponent, $0.hasVideoComponent])
            })
        }
        var description: String { rows.sorted { $0.key < $1.key }.description }
    }

    private let date = Date(timeIntervalSinceReferenceDate: 700_000_000)

    private func diskItem(id: String, type: MediaType, subtype: MediaFilterOptions) -> MediaWithMetadata<EncryptedMedia> {
        MediaWithMetadata(
            media: EncryptedMedia(source: URL(fileURLWithPath: "/tmp/\(id).enc"), mediaType: type, id: id),
            metadata: nil,
            dateTaken: date,
            dateEncrypted: date,
            mediaSubtype: subtype
        )
    }

    private func cloudMeta(id: String, type: MediaType) -> CloudKitMediaMetadata {
        CloudKitMediaMetadata(
            recordName: "\(id)#\(type.rawValue)",
            albumID: "album",
            mediaID: id,
            mediaType: type,
            createdAt: date,
            sizeBytes: 0,
            creationDeviceID: "device",
            schemaVersion: 1,
            recordChangeTag: nil
        )
    }

    /// Feed a Live Photo (photo + video components sharing an id) and a video-only
    /// item through both backends' mapping → upsert sequences; the resulting index
    /// shapes must be equal.
    func testDiskAndCloudProduceEquivalentIndexForSameMedia() {
        let livePhotoID = "live-photo-1"
        let videoID = "video-1"

        // Disk path: one file-level item per component. The disk reader reclassifies
        // a Live Photo's video component to `.stillImage`, so both its components
        // arrive as still images.
        var diskIndex: [MediaIndexEntry] = []
        for item in [
            diskItem(id: livePhotoID, type: .photo, subtype: .stillImage),
            diskItem(id: livePhotoID, type: .video, subtype: .stillImage),
            diskItem(id: videoID, type: .video, subtype: .video)
        ] {
            diskIndex.upsert(DiskMediaBackend.entry(forFileLevelMetadata: item))
        }

        // Cloud path: one CloudKit component record per component, same logical media.
        var cloudIndex: [MediaIndexEntry] = []
        for meta in [
            cloudMeta(id: livePhotoID, type: .photo),
            cloudMeta(id: livePhotoID, type: .video),
            cloudMeta(id: videoID, type: .video)
        ] {
            cloudIndex.upsert(CloudKitSyncCoordinator.indexEntry(from: meta))
        }

        XCTAssertEqual(
            Shape(diskIndex), Shape(cloudIndex),
            "disk and cloud must produce the same id grouping and component flags for the same media"
        )

        // Spot-check the merged shape itself so the test fails loudly if BOTH
        // backends drift the same way.
        XCTAssertEqual(diskIndex.count, 2, "the two live-photo components collapse into one entry")
        let livePhoto = diskIndex.first { $0.id == livePhotoID }
        XCTAssertEqual([livePhoto?.hasPhotoComponent, livePhoto?.hasVideoComponent], [true, true])
        let video = diskIndex.first { $0.id == videoID }
        XCTAssertEqual([video?.hasPhotoComponent, video?.hasVideoComponent], [false, true])
    }
}
