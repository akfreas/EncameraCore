//
//  KeyDiscoveryPerformanceTests.swift
//  EncameraCoreTests
//
//  Cost of key discovery across a whole album, for the case that actually hurts:
//  an album whose key this device does NOT hold.
//
//  Why this case and not the happy path. On a resolvable album the sweep stops at
//  the first candidate that authenticates, and `DiskFileAccess.discoveredKeyMemo`
//  remembers it, so steady-state cost is one AEAD op per file. When no stored key
//  opens the media, every candidate is tried on every file, the negative result is
//  never memoized (`resolveKey` only records successes), and `loadMediaPreview`
//  rethrows before reaching its preview cache — so the full sweep repeats on every
//  scroll and every re-entry into the album. That is the shape the rig shows as
//  "N album(s) can't be shown because their key isn't on this device".
//
//  Every case asserts the answer its measurement depends on, because a call that
//  fails is faster than a call that works: a probe returning nil, an empty fixture
//  directory, or a keychain query that never happens would otherwise all read as
//  an improvement. No `.xcbaseline` is stored for this target, so the timings
//  themselves are numbers to read off the log, not thresholds.
//
//  Runs in the ordinary unit suite: building the 120 fixtures and sweeping them
//  costs about four seconds in total. Run the class on its own with:
//
//    xcodebuild test -project Encamera.xcodeproj -scheme EncameraTests \
//      -destination 'id=<UDID>' \
//      -only-testing:EncameraCoreTests/KeyDiscoveryPerformanceTests
//

import XCTest
import Combine
import Security
@testable import EncameraCore

final class KeyDiscoveryPerformanceTests: XCTestCase {

    /// Two pages of the gallery grid, which pages at 60.
    private let fileCount = 120
    /// A plausible upper end for a key library on the shared rig account.
    private let storedKeyCount = 8

    private var tempDirectory: URL!
    private var fixtures: [URL] = []
    private var fixtureError: Error?
    private var keyManager: DemoKeyManager!

    /// The key the media is actually encrypted under — deliberately NOT in the
    /// key manager, so every discovery exhausts the candidate list.
    private let foreignKey = PrivateKey(name: "foreign",
                                        keyBytes: Array(repeating: 0x11, count: 32),
                                        creationDate: Date(timeIntervalSince1970: 0))

    /// Multi-block plaintext so the first block is a full 20480-byte block —
    /// the same shape `FirstBlockProbe` reads in production.
    private let plaintext = Data((0..<50000).map { UInt8($0 % 251) })

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeyDiscoveryPerf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        let storedKeys = (0..<storedKeyCount).map { index in
            PrivateKey(name: "stored-\(index)",
                       keyBytes: Array(repeating: UInt8(0x20 + index), count: 32),
                       creationDate: Date(timeIntervalSince1970: 0))
        }
        keyManager = DemoKeyManager(keys: storedKeys)
        keyManager.currentKey = storedKeys.first

        let expectation = expectation(description: "fixtures encrypted")
        Task {
            for index in 0..<self.fileCount {
                let name = "perf-\(index)"
                let cleartext = CleartextMedia(source: self.plaintext, mediaType: .photo, id: name)
                let url = self.tempDirectory.appendingPathComponent("\(name).encifile")
                let handler = SecretFileHandlerV2(keyBytes: self.foreignKey.keyBytes,
                                                  source: cleartext,
                                                  targetURL: url)
                do {
                    _ = try await handler.encryptWithMetadata(EncryptedFileMetadata())
                } catch {
                    self.fixtureError = error
                    break
                }
                self.fixtures.append(url)
            }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 300)
        if let fixtureError {
            throw fixtureError
        }
        XCTAssertEqual(fixtures.count, fileCount, "fixture setup should have produced every file")

        // Every benchmark below is only interpretable if the fixtures are real
        // encrypted media: a file that cannot be opened or parsed is measured as
        // an early return, not as the work being timed.
        for url in fixtures {
            let probe = try XCTUnwrap(FirstBlockProbe(url: url),
                                      "fixture \(url.lastPathComponent) is not readable encrypted media")
            guard probe.authenticates(keyBytes: foreignKey.keyBytes) else {
                throw UnusableFixture(url: url)
            }
        }
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        fixtures = []
        fixtureError = nil
        try super.tearDownWithError()
    }

    /// The album-open path: `DiskFileAccess.resolveKey` -> `discoverKeyOutcome`
    /// for every item whose thumbnail is being loaded.
    func testDiscoverKeyOutcomeAcrossAlbumWithNoHeldKey() throws {
        measure {
            let expectation = expectation(description: "sweep complete")
            Task {
                for url in self.fixtures {
                    let outcome = await KeyDiscovery.discoverKeyOutcome(for: url, keyManager: self.keyManager)
                    guard case .noKnownKey = outcome else {
                        XCTFail("fixture should be unopenable by every stored key, got \(outcome)")
                        return expectation.fulfill()
                    }
                }
                expectation.fulfill()
            }
            wait(for: [expectation], timeout: 300)
        }
    }

    // MARK: - Cost decomposition
    //
    // The two benchmarks above measure whole paths. These isolate the pieces so
    // the difference between them can be attributed rather than guessed:
    //
    //   proveFirstBlock  = probe + 1 AEAD
    //   discoverKeyOutcome = probe + readStamp + (storedKeyCount) AEAD
    //
    // so measuring `readStamp` and the bare probe on their own pins down what
    // each part of that gap actually costs.

    /// `KeyStampSlot.readStamp` on its own: a second open of a file the probe
    /// has already opened and parsed.
    ///
    /// The fixtures are stamped first so the read returns a value — an unstamped
    /// file's zero slot is indistinguishable here from a read that failed.
    func testReadStampOnlyAcrossAlbum() throws {
        for url in fixtures {
            KeyStampSlot.writeStamp(foreignKey.stampPrefix, url: url)
        }
        XCTAssertEqual(KeyStampSlot.readStamp(url: try XCTUnwrap(fixtures.first)),
                       foreignKey.stampPrefix,
                       "the fixtures must carry a stamp for this to measure a full read")

        measure {
            for url in fixtures {
                guard KeyStampSlot.readStamp(url: url) == foreignKey.stampPrefix else {
                    XCTFail("stamp read back from \(url.lastPathComponent) is not the one written")
                    return
                }
            }
        }
    }

    /// `FirstBlockProbe` construction on its own: one open, prologue parse, and
    /// the ~20KB first-block read, with no AEAD at all.
    func testFirstBlockProbeOnlyAcrossAlbum() throws {
        measure {
            for url in fixtures {
                // Pins that the whole block was read: a probe that returned nil,
                // or bailed after the prologue, would time a fraction of this.
                guard let probe = FirstBlockProbe(url: url),
                      probe.streamHeader.count == EncryptedFileFormat.streamHeaderSize,
                      probe.firstBlock.count > 20000 else {
                    XCTFail("probe should read the whole first block of \(url.lastPathComponent)")
                    return
                }
            }
        }
    }

    /// The cost the `DemoKeyManager` benchmarks above cannot see.
    ///
    /// `discoverKeyOutcome` calls `keyManager.storedKeys()` once per file. Under
    /// the demo double that is an array read; in production it is
    /// `KeychainManager.storedKeys()` — a `SecItemCopyMatching` with
    /// `kSecMatchLimitAll`, `kSecReturnData` and `kSecReturnAttributes`, i.e. a
    /// full keychain round-trip that decrypts every stored key, per image.
    ///
    /// Read-only: this queries whatever keys the device already holds and writes
    /// nothing. The count it found is printed so the number can be read in
    /// proportion, and the query counter pins each call to a real round-trip
    /// rather than something cheaper.
    func testStoredKeysQueryCostPerAlbumSweep() throws {
        let keychain = CountingKeychainWrapper()
        let real = KeychainManager(isAuthenticated: Just(true).eraseToAnyPublisher(),
                                   keychainWrapper: keychain)
        let library = try real.storedKeys().map(\.uuid)
        print("[KeyDiscoveryPerf] real keychain holds \(library.count) key(s)")

        keychain.reset()
        for _ in 0..<fileCount {
            XCTAssertEqual(try real.storedKeys().map(\.uuid), library)
        }
        XCTAssertEqual(keychain.copyMatchingCount, fileCount,
                       "every storedKeys() call is a keychain query of its own")

        measure {
            for _ in 0..<fileCount {
                guard (try? real.storedKeys())?.count == library.count else {
                    XCTFail("the key library changed under the benchmark")
                    return
                }
            }
        }
    }

    /// The SECOND keychain query per file that discovery used to make.
    ///
    /// Every file `DiskFileAccess` saves gets a key-UUID xattr, so on real local
    /// media the xattr-hint branch was always taken — and it resolved the UUID
    /// through `keyManager.keyWith(uuid:)`, which is itself a `storedKeys()`
    /// call. Two full keychain round-trips per image. Discovery now resolves the
    /// UUID against the snapshot it already holds; this measures what that
    /// removed.
    ///
    /// Note `keyWith(uuid:)` is main-actor isolated — it reads
    /// `UIApplication.shared.applicationState` — so the old discovery path also
    /// hopped to the main actor once per image, competing with the scrolling it
    /// was blocking.
    func testKeyWithUUIDQueryCostPerAlbumSweep() throws {
        let keychain = CountingKeychainWrapper()
        let real = KeychainManager(isAuthenticated: Just(true).eraseToAnyPublisher(),
                                   keychainWrapper: keychain)
        let stored = try real.storedKeys()
        let heldUUID = stored.first?.uuid
        let lookupUUID = heldUUID ?? UUID()

        keychain.reset()
        let lookups = expectation(description: "counted keyWith lookups")
        Task { @MainActor in
            var mismatches = 0
            for _ in 0..<self.fileCount {
                if real.keyWith(uuid: lookupUUID)?.uuid != heldUUID {
                    mismatches += 1
                }
            }
            XCTAssertEqual(mismatches, 0,
                           "keyWith(uuid:) must resolve exactly the key the library holds, or nothing when it holds none")
            // A uuid the library does not contain must miss whatever the library
            // holds: the lookup is not allowed to fall back to whichever key
            // happens to be current.
            XCTAssertNil(real.keyWith(uuid: UUID()))
            lookups.fulfill()
        }
        wait(for: [lookups], timeout: 300)
        XCTAssertEqual(keychain.copyMatchingCount, fileCount + 1,
                       "every keyWith(uuid:) is a full keychain query of its own")

        measure {
            let expectation = expectation(description: "keyWith sweep")
            Task { @MainActor in
                for _ in 0..<self.fileCount {
                    _ = real.keyWith(uuid: lookupUUID)
                }
                expectation.fulfill()
            }
            wait(for: [expectation], timeout: 300)
        }
    }

    // MARK: - The keychain hoist, A/B against the real keychain
    //
    // The DemoKeyManager benchmarks cannot see this: their `storedKeys()` is an
    // array read. These two run the identical sweep against a real
    // `KeychainManager`, differing only in whether the key library is read once
    // for the album or once per file. Read-only — neither writes a key.
    //
    // The claim the pair exists to make — the hoist removes keychain queries —
    // is asserted from a query counter, not from the two timings, which have no
    // baseline to fail against.

    /// Old behavior: discovery reads the keychain itself, per file.
    func testRealKeychainSweepWithoutSnapshot() throws {
        let keychain = CountingKeychainWrapper()
        let real = KeychainManager(isAuthenticated: Just(true).eraseToAnyPublisher(),
                                   keychainWrapper: keychain)

        let queries = try sweepAlbumCountingQueries(keyManager: real, keychain: keychain, useSnapshot: false)
        XCTAssertEqual(queries, fixtures.count,
                       "without a snapshot the key library is read once per file")

        measure {
            let expectation = expectation(description: "sweep")
            Task {
                for url in self.fixtures {
                    let outcome = await KeyDiscovery.discoverKeyOutcome(for: url, keyManager: real)
                    guard case .noKnownKey = outcome else {
                        XCTFail("fixture should be unopenable by every stored key, got \(outcome)")
                        return expectation.fulfill()
                    }
                }
                expectation.fulfill()
            }
            wait(for: [expectation], timeout: 300)
        }
    }

    /// New behavior: the caller reads the key library once for the sweep.
    func testRealKeychainSweepWithSnapshot() throws {
        let keychain = CountingKeychainWrapper()
        let real = KeychainManager(isAuthenticated: Just(true).eraseToAnyPublisher(),
                                   keychainWrapper: keychain)

        let snapshotQueries = try sweepAlbumCountingQueries(keyManager: real, keychain: keychain, useSnapshot: true)
        XCTAssertEqual(snapshotQueries, 1,
                       "the key library is read once for the whole album")

        let perFileQueries = try sweepAlbumCountingQueries(keyManager: real, keychain: keychain, useSnapshot: false)
        XCTAssertLessThan(snapshotQueries, perFileQueries,
                          "hoisting the key library out of the per-file path must remove keychain queries")

        measure {
            let expectation = expectation(description: "sweep")
            Task {
                let snapshot = (try? real.storedKeys()) ?? []
                for url in self.fixtures {
                    let outcome = await KeyDiscovery.discoverKeyOutcome(for: url,
                                                                        keyManager: real,
                                                                        storedKeysSnapshot: snapshot)
                    guard case .noKnownKey = outcome else {
                        XCTFail("fixture should be unopenable by every stored key, got \(outcome)")
                        return expectation.fulfill()
                    }
                }
                expectation.fulfill()
            }
            wait(for: [expectation], timeout: 300)
        }
    }

    /// One album sweep through `discoverKeyOutcome`, asserting the outcome of
    /// every file and reporting how many keychain queries the sweep made.
    private func sweepAlbumCountingQueries(keyManager: KeyManager,
                                           keychain: CountingKeychainWrapper,
                                           useSnapshot: Bool,
                                           file: StaticString = #filePath,
                                           line: UInt = #line) throws -> Int {
        keychain.reset()
        var snapshot: [PrivateKey]?
        if useSnapshot {
            snapshot = try keyManager.storedKeys()
        }
        let expectation = expectation(description: "counted sweep")
        Task {
            for url in self.fixtures {
                let outcome = await KeyDiscovery.discoverKeyOutcome(for: url,
                                                                    keyManager: keyManager,
                                                                    storedKeysSnapshot: snapshot)
                guard case .noKnownKey = outcome else {
                    XCTFail("fixture should be unopenable by every stored key, got \(outcome)",
                            file: file, line: line)
                    return expectation.fulfill()
                }
            }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 300)
        return keychain.copyMatchingCount
    }

    /// Runs the album sweep on a loop long enough for a sampling profiler to
    /// collect a usable number of samples. Not an assertion about speed — it
    /// exists so `xctrace record --template 'Time Profiler' --attach Encamera`
    /// has something steady to sample, and asserts only that the workload the
    /// trace is recorded against really swept the album. One second by default
    /// so the ordinary suite still executes it; set ENCAMERA_PERF_SOAK_SECONDS
    /// to the length a trace needs.
    func testSoakDiscoverKeyOutcomeForProfiler() throws {
        let soakSeconds = TimeInterval(ProcessInfo.processInfo.environment["ENCAMERA_PERF_SOAK_SECONDS"] ?? "") ?? 1
        // Soaks the REAL keychain path, because that is where the cost was.
        // ENCAMERA_PERF_SOAK_NOSNAPSHOT=1 reproduces the pre-fix shape (the key
        // library re-read per file) so two traces of the same workload can be
        // compared directly.
        let useSnapshot = ProcessInfo.processInfo.environment["ENCAMERA_PERF_SOAK_NOSNAPSHOT"] != "1"
        let real = KeychainManager(isAuthenticated: Just(true).eraseToAnyPublisher())
        print("[KeyDiscoveryPerf] soak mode: \(useSnapshot ? "WITH snapshot (fixed)" : "WITHOUT snapshot (pre-fix)")")

        let counters = SoakCounters()
        let expectation = expectation(description: "soak complete")
        Task {
            let deadline = Date().addingTimeInterval(soakSeconds)
            while Date() < deadline {
                let snapshot = useSnapshot ? ((try? real.storedKeys()) ?? []) : nil
                for url in self.fixtures {
                    let outcome = await KeyDiscovery.discoverKeyOutcome(for: url,
                                                                        keyManager: real,
                                                                        storedKeysSnapshot: snapshot)
                    counters.record(outcome)
                }
                counters.finishSweep()
            }
            print("[KeyDiscoveryPerf] completed \(counters.sweeps) sweeps of \(self.fileCount) files in \(Int(soakSeconds))s")
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: soakSeconds + 120)

        XCTAssertGreaterThan(counters.sweeps, 0, "the profiled workload completed no sweeps")
        XCTAssertEqual(counters.files, counters.sweeps * fileCount,
                       "every sweep must cover the whole album")
        XCTAssertEqual(counters.unexpectedOutcomes, 0,
                       "the profiled workload must exercise the full candidate sweep, not an early return")
    }

    /// The additive-key-entry path: `GalleryGridViewModel.proveKey` probes every
    /// item in the album, and a rejected phrase never short-circuits.
    func testProveFirstBlockAcrossAlbumWithWrongKey() throws {
        let wrongKey = PrivateKey(name: "wrong",
                                  keyBytes: Array(repeating: 0x99, count: 32),
                                  creationDate: Date(timeIntervalSince1970: 0))
        measure {
            let expectation = expectation(description: "probe complete")
            Task {
                for url in self.fixtures {
                    let outcome = await KeyDiscovery.proveFirstBlock(of: url, with: wrongKey)
                    XCTAssertEqual(outcome, .disproved)
                }
                expectation.fulfill()
            }
            wait(for: [expectation], timeout: 300)
        }
    }
}

/// A fixture that was written but does not decrypt under the key it was written
/// with — the benchmarks would time it as a failed open.
private struct UnusableFixture: Error, CustomStringConvertible {
    let url: URL
    var description: String {
        "fixture \(url.lastPathComponent) does not decrypt under the key it was written with"
    }
}

/// A real keychain with its `SecItemCopyMatching` calls counted, so "one query
/// per file" and "one query per album" can be asserted instead of inferred from
/// two wall-clock numbers. Every call goes straight through.
private final class CountingKeychainWrapper: KeychainWrapperProtocol {

    private let underlying = KeychainWrapper()
    private let lock = NSLock()
    private var count = 0

    var copyMatchingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        count = 0
    }

    func secItemAdd(_ attributes: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        underlying.secItemAdd(attributes, result)
    }

    func secItemCopyMatching(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        lock.lock()
        count += 1
        lock.unlock()
        return underlying.secItemCopyMatching(query, result)
    }

    func secItemUpdate(_ query: CFDictionary, _ attributesToUpdate: CFDictionary) -> OSStatus {
        underlying.secItemUpdate(query, attributesToUpdate)
    }

    func secItemDelete(_ query: CFDictionary) -> OSStatus {
        underlying.secItemDelete(query)
    }
}

/// Tally of what the soak workload actually did, so a trace recorded against it
/// can be shown to have swept the album rather than returned early.
private final class SoakCounters {

    private let lock = NSLock()
    private var sweepCount = 0
    private var visitedFiles = 0
    private var unexpected = 0

    var sweeps: Int {
        lock.lock()
        defer { lock.unlock() }
        return sweepCount
    }

    var files: Int {
        lock.lock()
        defer { lock.unlock() }
        return visitedFiles
    }

    var unexpectedOutcomes: Int {
        lock.lock()
        defer { lock.unlock() }
        return unexpected
    }

    func record(_ outcome: KeyDiscoveryOutcome) {
        lock.lock()
        defer { lock.unlock() }
        visitedFiles += 1
        if case .noKnownKey = outcome {
            return
        }
        unexpected += 1
    }

    func finishSweep() {
        lock.lock()
        defer { lock.unlock() }
        sweepCount += 1
    }
}
