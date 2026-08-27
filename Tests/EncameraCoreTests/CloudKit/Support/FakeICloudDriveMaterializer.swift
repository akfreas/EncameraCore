//
//  FakeICloudDriveMaterializer.swift
//  EncameraCoreTests
//
//  Stands in for iCloud Drive on a machine that has none.
//
//  Neither a simulator nor a unit-test host has a ubiquity container, so
//  `startDownloadingUbiquitousItem` and the NSMetadataQuery notifications the real
//  `ICloudDriveMaterializer` is built on can never fire here. This fake models the
//  one thing the migration engine actually depends on — a file that exists only as
//  a `.icloud` placeholder until something downloads it — by moving the real bytes
//  aside and putting them back on demand.
//
//  It is deliberately NOT a substitute for the device tests: the machinery most
//  likely to be wrong (Apple's download observation) is exactly what this replaces.
//  What it does pin down is the engine's contract around materialization — batch
//  sizes, what happens to a file that never arrives, and whether sizes survive.
//

import Foundation
@testable import EncameraCore

@MainActor
final class FakeICloudDriveMaterializer: ICloudDriveMaterializing {

    /// Where evicted bytes are parked, keyed by the materialized URL.
    private var evictedContents: [URL: Data] = [:]
    /// Real byte sizes of evicted files, i.e. what iCloud's metadata index would report.
    private var evictedSizes: [URL: Int64] = [:]

    /// Materialized filenames the fake refuses to download, modelling a stalled or
    /// failed transfer. The bytes stay parked, so the placeholder remains on disk.
    var urlsThatFailToMaterialize: Set<String> = []

    /// One entry per `materialize` call, in order, holding that batch's size. The
    /// batching contract is asserted against this.
    private(set) var batchSizes: [Int] = []
    /// Materialized filenames handed to each `materialize` call, in order.
    private(set) var requestedBatches: [[String]] = []
    /// Materialized filenames passed to `evict`, across all calls.
    private(set) var evictedOnStop: [String] = []
    /// Set by the test to run assertions at the moment a batch is requested — used
    /// to prove batch k+1 is not requested until batch k's sources are gone.
    var onMaterialize: ((_ batchIndex: Int) async -> Void)?

    // MARK: - Seeding

    /// How the fake models an evicted file. Two shapes exist in the wild and the
    /// engine must survive both.
    enum EvictionShape {
        /// What iOS actually does, and what broke on the rig: the file keeps its
        /// path, so `fileExists` still answers `true`, while its bytes live only in
        /// iCloud. Only the download status distinguishes it from a real file.
        case pathPersists
        /// The `.<name>.icloud` brick — a Finder convention, and the shape the app's
        /// older enumeration code was written against.
        case replacedByPlaceholderBrick
    }

    /// Turns a real on-disk ciphertext into an iCloud Drive placeholder.
    ///
    /// Defaults to `.pathPersists` because that is what a real device does. The
    /// original version of this fake only modelled the brick, which is why the unit
    /// suite was green while the device uploaded placeholders to CloudKit.
    func evictForTest(_ url: URL, shape: EvictionShape = .pathPersists) throws {
        let data = try Data(contentsOf: url)
        evictedContents[url] = data
        evictedSizes[url] = Int64(data.count)

        switch shape {
        case .pathPersists:
            // Bytes replaced by a stub, path intact — and reported as evicted
            // through the same seam the engine consults on a device.
            try Data("placeholder".utf8).write(to: url)
            var evicted = ICloudPlaceholderName.testEvictedURLs ?? []
            evicted.insert(url.standardizedFileURL)
            ICloudPlaceholderName.testEvictedURLs = evicted
        case .replacedByPlaceholderBrick:
            try FileManager.default.removeItem(at: url)
            try Data("placeholder".utf8)
                .write(to: ICloudPlaceholderName.placeholderURL(forMaterialized: url))
        }
    }

    /// Marks a URL materialized again, undoing `evictForTest`'s status override.
    private func markMaterialized(_ url: URL) {
        ICloudPlaceholderName.testEvictedURLs?.remove(url.standardizedFileURL)
    }

    var isEvicted: (URL) -> Bool { { [weak self] in self?.evictedContents[$0] != nil } }

    // MARK: - ICloudDriveMaterializing

    func logicalSizes(inAlbumDirectory directory: URL) async -> [String: Int64] {
        var sizes: [String: Int64] = [:]
        for (url, size) in evictedSizes where url.deletingLastPathComponent() == directory {
            sizes[url.lastPathComponent] = size
        }
        return sizes
    }

    func materialize(_ urls: [URL],
                     inAlbumDirectory directory: URL,
                     onProgress: @escaping (Double) -> Void) async -> [URL: Result<URL, Error>] {
        await onMaterialize?(batchSizes.count)
        batchSizes.append(urls.count)
        requestedBatches.append(urls.map(\.lastPathComponent).sorted())

        var results: [URL: Result<URL, Error>] = [:]
        for url in urls {
            if urlsThatFailToMaterialize.contains(url.lastPathComponent) {
                results[url] = .failure(
                    ICloudMaterializationError.timedOut(filename: url.lastPathComponent))
                continue
            }
            guard let data = evictedContents[url] else {
                // Never evicted (or already back) — the real materializer short-
                // circuits the same way when the file is already on disk.
                results[url] = .success(url)
                continue
            }
            do {
                try data.write(to: url)
                try? FileManager.default.removeItem(
                    at: ICloudPlaceholderName.placeholderURL(forMaterialized: url))
                evictedContents[url] = nil
                markMaterialized(url)
                results[url] = .success(url)
            } catch {
                results[url] = .failure(error)
            }
        }
        onProgress(1)
        return results
    }

    @discardableResult
    func evict(_ urls: [URL]) -> [URL] {
        var evicted: [URL] = []
        for url in urls where ICloudPlaceholderName.isMaterialized(url) {
            evictedOnStop.append(url.lastPathComponent)
            do {
                try evictForTest(url)
                evicted.append(url)
            } catch {
                continue
            }
        }
        return evicted
    }
}
