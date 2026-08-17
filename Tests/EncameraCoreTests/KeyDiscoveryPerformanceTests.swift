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
//  Gated behind ENCAMERA_PERF so the ordinary suite does not pay for building
//  fixtures. Run it with:
//
//    ENCAMERA_PERF=1 xcodebuild test -project Encamera.xcodeproj \
//      -scheme EncameraDeviceSmoke -destination 'id=<UDID>' \
//      -only-testing:EncameraCoreTests/KeyDiscoveryPerformanceTests
//

import XCTest
import Combine
@testable import EncameraCore

final class KeyDiscoveryPerformanceTests: XCTestCase {

    /// Two pages of the gallery grid, which pages at 60.
    private let fileCount = 120
    /// A plausible upper end for a key library on the shared rig account.
    private let storedKeyCount = 8

    private var tempDirectory: URL!
    private var fixtures: [URL] = []
    private var keyManager: DemoKeyManager!

    /// The key the media is actually encrypted under — deliberately NOT in the
    /// key manager, so every discovery exhausts the candidate list.
    private let foreignKey = PrivateKey(name: "foreign",
                                        keyBytes: Array(repeating: 0x11, count: 32),
                                        creationDate: Date(timeIntervalSince1970: 0))

    /// Multi-block plaintext so the first block is a full 20480-byte block —
    /// the same shape `FirstBlockProbe` reads in production.
    private let plaintext = Data((0..<50000).map { UInt8($0 % 251) })

    private func skipUnlessPerfRun() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ENCAMERA_PERF"] == "1",
                          "Performance benchmark — set ENCAMERA_PERF=1 to run.")
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        try skipUnlessPerfRun()

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
                _ = try? await handler.encryptWithMetadata(EncryptedFileMetadata())
                self.fixtures.append(url)
            }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 300)
        XCTAssertEqual(fixtures.count, fileCount, "fixture setup should have produced every file")
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        fixtures = []
        try super.tearDownWithError()
    }

    /// The album-open path: `DiskFileAccess.resolveKey` -> `discoverKeyOutcome`
    /// for every item whose thumbnail is being loaded.
    func testDiscoverKeyOutcomeAcrossAlbumWithNoHeldKey() throws {
        try skipUnlessPerfRun()

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
    func testReadStampOnlyAcrossAlbum() throws {
        try skipUnlessPerfRun()
        measure {
            for url in fixtures {
                _ = KeyStampSlot.readStamp(url: url)
            }
        }
    }

    /// `FirstBlockProbe` construction on its own: one open, prologue parse, and
    /// the ~20KB first-block read, with no AEAD at all.
    func testFirstBlockProbeOnlyAcrossAlbum() throws {
        try skipUnlessPerfRun()
        measure {
            for url in fixtures {
                _ = FirstBlockProbe(url: url)
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
    /// proportion.
    func testStoredKeysQueryCostPerAlbumSweep() throws {
        try skipUnlessPerfRun()

        let real = KeychainManager(isAuthenticated: Just(true).eraseToAnyPublisher())
        let found = (try? real.storedKeys())?.count ?? -1
        print("[KeyDiscoveryPerf] real keychain holds \(found) key(s)")

        measure {
            for _ in 0..<fileCount {
                _ = try? real.storedKeys()
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
        try skipUnlessPerfRun()
        let real = KeychainManager(isAuthenticated: Just(true).eraseToAnyPublisher())
        let anyUUID = (try? real.storedKeys())?.first?.uuid ?? UUID()
        measure {
            let expectation = expectation(description: "keyWith sweep")
            Task { @MainActor in
                for _ in 0..<self.fileCount {
                    _ = real.keyWith(uuid: anyUUID)
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

    /// Old behavior: discovery reads the keychain itself, per file.
    func testRealKeychainSweepWithoutSnapshot() throws {
        try skipUnlessPerfRun()
        let real = KeychainManager(isAuthenticated: Just(true).eraseToAnyPublisher())
        measure {
            let expectation = expectation(description: "sweep")
            Task {
                for url in self.fixtures {
                    _ = await KeyDiscovery.discoverKeyOutcome(for: url, keyManager: real)
                }
                expectation.fulfill()
            }
            wait(for: [expectation], timeout: 300)
        }
    }

    /// New behavior: the caller reads the key library once for the sweep.
    func testRealKeychainSweepWithSnapshot() throws {
        try skipUnlessPerfRun()
        let real = KeychainManager(isAuthenticated: Just(true).eraseToAnyPublisher())
        measure {
            let expectation = expectation(description: "sweep")
            Task {
                let snapshot = (try? real.storedKeys()) ?? []
                for url in self.fixtures {
                    _ = await KeyDiscovery.discoverKeyOutcome(for: url,
                                                              keyManager: real,
                                                              storedKeysSnapshot: snapshot)
                }
                expectation.fulfill()
            }
            wait(for: [expectation], timeout: 300)
        }
    }

    /// Runs the album sweep on a loop long enough for a sampling profiler to
    /// collect a usable number of samples. Not an assertion about speed — it
    /// exists so `xctrace record --template 'Time Profiler' --attach Encamera`
    /// has something steady to sample. Opt-in separately from the benchmarks
    /// above, since it deliberately burns wall-clock.
    func testSoakDiscoverKeyOutcomeForProfiler() throws {
        try skipUnlessPerfRun()
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ENCAMERA_PERF_SOAK"] == "1",
                          "Profiler soak — set ENCAMERA_PERF_SOAK=1 to run.")

        let soakSeconds = TimeInterval(ProcessInfo.processInfo.environment["ENCAMERA_PERF_SOAK_SECONDS"] ?? "") ?? 25
        // Soaks the REAL keychain path, because that is where the cost was.
        // ENCAMERA_PERF_SOAK_NOSNAPSHOT=1 reproduces the pre-fix shape (the key
        // library re-read per file) so two traces of the same workload can be
        // compared directly.
        let useSnapshot = ProcessInfo.processInfo.environment["ENCAMERA_PERF_SOAK_NOSNAPSHOT"] != "1"
        let real = KeychainManager(isAuthenticated: Just(true).eraseToAnyPublisher())
        print("[KeyDiscoveryPerf] soak mode: \(useSnapshot ? "WITH snapshot (fixed)" : "WITHOUT snapshot (pre-fix)")")

        let expectation = expectation(description: "soak complete")
        Task {
            let deadline = Date().addingTimeInterval(soakSeconds)
            var sweeps = 0
            while Date() < deadline {
                let snapshot = useSnapshot ? ((try? real.storedKeys()) ?? []) : nil
                for url in self.fixtures {
                    _ = await KeyDiscovery.discoverKeyOutcome(for: url,
                                                              keyManager: real,
                                                              storedKeysSnapshot: snapshot)
                }
                sweeps += 1
            }
            print("[KeyDiscoveryPerf] completed \(sweeps) sweeps of \(self.fileCount) files in \(Int(soakSeconds))s")
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: soakSeconds + 120)
    }

    /// The additive-key-entry path: `GalleryGridViewModel.proveKey` probes every
    /// item in the album, and a rejected phrase never short-circuits.
    func testProveFirstBlockAcrossAlbumWithWrongKey() throws {
        try skipUnlessPerfRun()

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
