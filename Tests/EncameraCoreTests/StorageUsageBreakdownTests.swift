import XCTest
@testable import EncameraCore

final class StorageUsageBreakdownTests: XCTestCase {

    /// The data-loss guard, and the reason this type exists: "Free up space" is wired
    /// to `reclaimableBytes`, and `.local` media is the only copy in existence.
    func testReclaimableBytesExcludesLocalMedia() {
        let breakdown = StorageUsageBreakdown(localMediaBytes: 5_000_000)

        XCTAssertEqual(breakdown.reclaimableBytes, 0)
        XCTAssertEqual(breakdown.totalDeviceBytes, 5_000_000)
    }

    /// Every re-fetchable bucket contributes, so adding a bucket later without
    /// updating the accessor fails here rather than under-reporting on screen.
    func testReclaimableBytesSumsEveryRefetchableBucket() {
        let breakdown = StorageUsageBreakdown(
            localMediaBytes: 1_000,
            cachedCloudBytes: 200,
            thumbnailBytes: 30,
            indexBytes: 4
        )

        XCTAssertEqual(breakdown.reclaimableBytes, 234)
        XCTAssertEqual(breakdown.totalDeviceBytes, 1_234)
    }

    func testTotalDeviceBytesNeverLessThanReclaimable() {
        let cases: [StorageUsageBreakdown] = [
            StorageUsageBreakdown(),
            StorageUsageBreakdown(localMediaBytes: 1),
            StorageUsageBreakdown(cachedCloudBytes: 1),
            StorageUsageBreakdown(thumbnailBytes: 1, indexBytes: 1),
            StorageUsageBreakdown(
                localMediaBytes: 900_000_000,
                cachedCloudBytes: 500_000_000,
                thumbnailBytes: 12_345,
                indexBytes: 678,
                cloudBytes: 9_000_000_000
            ),
        ]

        for breakdown in cases {
            XCTAssertLessThanOrEqual(breakdown.reclaimableBytes, breakdown.totalDeviceBytes)
            XCTAssertGreaterThanOrEqual(breakdown.reclaimableBytes, 0)
        }
    }

    /// Pins the overlap semantics: a fully-cached library reports the same
    /// `cloudBytes` it would report cached or not, and the device total counts those
    /// bytes exactly once.
    func testCachedCloudBytesIsNotAddedToCloudBytes() {
        let fullyCached = StorageUsageBreakdown(cachedCloudBytes: 750, cloudBytes: 750)

        XCTAssertEqual(fullyCached.cloudBytes, 750)
        XCTAssertEqual(fullyCached.totalDeviceBytes, 750)

        let nothingCached = StorageUsageBreakdown(cachedCloudBytes: 0, cloudBytes: 750)
        XCTAssertEqual(nothingCached.cloudBytes, fullyCached.cloudBytes)
        XCTAssertEqual(nothingCached.totalDeviceBytes, 0)
    }

    func testUnavailableCloudBytesIsDistinctFromZero() {
        XCTAssertNil(StorageUsageBreakdown().cloudBytes)
        XCTAssertEqual(StorageUsageBreakdown(cloudBytes: 0).cloudBytes, 0)
    }

    func testNegativeBucketsAreClampedToZero() {
        let breakdown = StorageUsageBreakdown(
            localMediaBytes: -1,
            cachedCloudBytes: -2,
            thumbnailBytes: -3,
            indexBytes: -4,
            cloudBytes: -5,
            legacyICloudDriveAlbumCount: -6
        )

        XCTAssertEqual(breakdown.totalDeviceBytes, 0)
        XCTAssertEqual(breakdown.cloudBytes, 0)
        XCTAssertEqual(breakdown.legacyICloudDriveAlbumCount, 0)
        XCTAssertTrue(breakdown.isEmpty)
    }
}
