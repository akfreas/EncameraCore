import XCTest
@testable import EncameraCore

/// Fingerprint-gated additive key entry (ENC-99 steps 5 and 6).
final class MissingKeyEntryTests: XCTestCase {

    private var tempDirectory: URL!
    private let deviceKey = PrivateKey(name: "encamera_default_key", keyBytes: Array(repeating: 0x42, count: 32), creationDate: Date(timeIntervalSince1970: 0))

    private let plaintext = Data((0..<50000).map { UInt8($0 % 251) })

    /// Phrases the demo key manager derives distinct, deterministic keys from.
    private let foreignPhrase = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot"]
    private let wrongPhrase = ["zulu", "yankee", "xray", "whiskey", "victor", "uniform"]

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MissingKeyEntryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    private func encryptFixture(with key: PrivateKey, name: String) async throws -> URL {
        let cleartext = CleartextMedia(source: plaintext, mediaType: .photo, id: name)
        let url = tempDirectory.appendingPathComponent("\(name).encifile")
        let handler = SecretFileHandlerV2(keyBytes: key.keyBytes, source: cleartext, targetURL: url)
        _ = try await handler.encryptWithMetadata(EncryptedFileMetadata())
        return url
    }

    /// A device holding only its own key, plus media encrypted under a foreign
    /// key derived from `foreignPhrase`.
    private func makeScenario(stamped: Bool = true) async throws -> (manager: DemoKeyManager, foreignKey: PrivateKey, mediaURL: URL) {
        let manager = DemoKeyManager(keys: [deviceKey])
        manager.currentKey = deviceKey
        let foreignKey = try manager.deriveKey(from: foreignPhrase, name: AppConstants.defaultKeyName)
        let url = try await encryptFixture(with: foreignKey, name: "foreign-media")
        if stamped {
            KeyStampSlot.writeStamp(foreignKey.stampPrefix, url: url)
        }
        return (manager, foreignKey, url)
    }

    private func verifier(for url: URL) -> (PrivateKey) async -> KeyProofOutcome {
        { key in await KeyDiscovery.proveFirstBlock(of: url, with: key) }
    }

    // MARK: - Acceptance

    func testAddedKeyMakesMediaReadable() async throws {
        let scenario = try await makeScenario()

        // Precondition: the media does not open today.
        let before = await KeyDiscovery.discoverKeyOutcome(for: scenario.mediaURL, keyManager: scenario.manager)
        XCTAssertEqual(before, .noKnownKey(requiredStampPrefix: scenario.foreignKey.stampPrefix))

        let added = try await MissingKeyEntry(keyManager: scenario.manager)
            .addKey(phraseComponents: foreignPhrase,
                    requiredStampPrefix: scenario.foreignKey.stampPrefix,
                    verify: verifier(for: scenario.mediaURL))

        XCTAssertEqual(added.keyBytes, scenario.foreignKey.keyBytes)

        // The whole point: the same media now resolves, with no restart.
        let after = await KeyDiscovery.discoverKeyOutcome(for: scenario.mediaURL, keyManager: scenario.manager)
        guard case .resolved(let result) = after else {
            return XCTFail("expected the media to open after adding its key, got \(after)")
        }
        XCTAssertEqual(result.key.keyBytes, scenario.foreignKey.keyBytes)
    }

    /// ENC-76's central invariant: an added key is decrypt-only. New media must
    /// keep being encrypted with this device's own key.
    func testAddedKeyDoesNotBecomeCurrent() async throws {
        let scenario = try await makeScenario()

        _ = try await MissingKeyEntry(keyManager: scenario.manager)
            .addKey(phraseComponents: foreignPhrase,
                    requiredStampPrefix: scenario.foreignKey.stampPrefix,
                    verify: verifier(for: scenario.mediaURL))

        XCTAssertEqual(scenario.manager.currentKey?.keyBytes, deviceKey.keyBytes,
                       "the added key must never be promoted to current")
        XCTAssertEqual(try scenario.manager.storedKeys().count, 2, "the library grew rather than being replaced")
        XCTAssertTrue(try scenario.manager.storedKeys().contains { $0.keyBytes == deviceKey.keyBytes },
                      "adding a key must never drop the device's own key")
    }

    /// Step 5: a wrong key is rejected with a specific message, and nothing is
    /// written to the keychain.
    func testAddingWrongKeyIsRejectedAndSavesNothing() async throws {
        let scenario = try await makeScenario()

        do {
            _ = try await MissingKeyEntry(keyManager: scenario.manager)
                .addKey(phraseComponents: wrongPhrase,
                        requiredStampPrefix: scenario.foreignKey.stampPrefix,
                        verify: verifier(for: scenario.mediaURL))
            XCTFail("a non-matching key must be rejected")
        } catch let error as MissingKeyEntryError {
            guard case .wrongKey(let entered, let required) = error else {
                return XCTFail("expected .wrongKey, got \(error)")
            }
            XCTAssertEqual(required, scenario.foreignKey.stampPrefix)
            XCTAssertNotEqual(entered, scenario.foreignKey.stampPrefix)
            // Specific, not generic: the message names both keys.
            XCTAssertTrue(error.displayDescription.contains(KeyFingerprint.displayLabel(stampPrefix: scenario.foreignKey.stampPrefix)),
                          "the rejection must name the key the media actually needs")
        }

        XCTAssertEqual(try scenario.manager.storedKeys().count, 1, "a rejected key must not reach the keychain")
    }

    /// With no fingerprint to compare against, the gate falls back to the
    /// authoritative check — an authenticated decrypt — rather than accepting
    /// anything. Rejection is still specific about what happened.
    func testWrongKeyRejectedEvenWithNoRequiredFingerprint() async throws {
        let scenario = try await makeScenario(stamped: false)

        do {
            _ = try await MissingKeyEntry(keyManager: scenario.manager)
                .addKey(phraseComponents: wrongPhrase,
                        requiredStampPrefix: nil,
                        verify: verifier(for: scenario.mediaURL))
            XCTFail("a non-matching key must be rejected even when the media names no key")
        } catch let error as MissingKeyEntryError {
            guard case .wrongKey(_, let required) = error else {
                return XCTFail("expected .wrongKey, got \(error)")
            }
            XCTAssertNil(required)
            XCTAssertEqual(error.displayDescription, L10n.MissingKey.wrongKeyUnknown)
        }
        XCTAssertEqual(try scenario.manager.storedKeys().count, 1)
    }

    /// The correct key is still accepted when the media carries no stamp — the
    /// decrypt proof stands on its own.
    func testCorrectKeyAcceptedWithNoRequiredFingerprint() async throws {
        let scenario = try await makeScenario(stamped: false)

        _ = try await MissingKeyEntry(keyManager: scenario.manager)
            .addKey(phraseComponents: foreignPhrase,
                    requiredStampPrefix: nil,
                    verify: verifier(for: scenario.mediaURL))

        let after = await KeyDiscovery.discoverKeyOutcome(for: scenario.mediaURL, keyManager: scenario.manager)
        guard case .resolved = after else {
            return XCTFail("expected the media to open, got \(after)")
        }
        XCTAssertEqual(scenario.manager.currentKey?.keyBytes, deviceKey.keyBytes)
    }

    func testAddingAKeyAlreadyHeldIsReportedDistinctly() async throws {
        let scenario = try await makeScenario()
        try scenario.manager.save(key: scenario.foreignKey, setNewKeyToCurrent: false)

        do {
            _ = try await MissingKeyEntry(keyManager: scenario.manager)
                .addKey(phraseComponents: foreignPhrase,
                        requiredStampPrefix: scenario.foreignKey.stampPrefix,
                        verify: verifier(for: scenario.mediaURL))
            XCTFail("expected .alreadyHeld")
        } catch let error as MissingKeyEntryError {
            XCTAssertEqual(error, .alreadyHeld)
        }
    }

    /// Step 6. An added, non-current key never goes through `setActiveKey`, so
    /// it never fires `keyPublisher` and none of ENC-97's rebuild happens. The
    /// stale artifact is the reconciler's locked-out count, so the add has to
    /// announce itself for that to be recomputed — without an app restart.
    func testSuccessfulAddAnnouncesKeyLibraryGrowth() async throws {
        let scenario = try await makeScenario()

        let expectation = expectation(forNotification: .keyLibraryDidGrow, object: nil, handler: nil)

        _ = try await MissingKeyEntry(keyManager: scenario.manager)
            .addKey(phraseComponents: foreignPhrase,
                    requiredStampPrefix: scenario.foreignKey.stampPrefix,
                    verify: verifier(for: scenario.mediaURL))

        await fulfillment(of: [expectation], timeout: 2)
    }

    /// The converse: a rejected key must not announce anything, or every failed
    /// attempt would kick off a pointless full reconcile.
    func testRejectedKeyAnnouncesNothing() async throws {
        let scenario = try await makeScenario()

        var posted = false
        let token = NotificationCenter.default.addObserver(forName: .keyLibraryDidGrow, object: nil, queue: nil) { _ in
            posted = true
        }
        defer { NotificationCenter.default.removeObserver(token) }

        _ = try? await MissingKeyEntry(keyManager: scenario.manager)
            .addKey(phraseComponents: wrongPhrase,
                    requiredStampPrefix: scenario.foreignKey.stampPrefix,
                    verify: verifier(for: scenario.mediaURL))

        XCTAssertFalse(posted)
    }

    /// The correct phrase, entered against an album whose media has not
    /// downloaded yet. `verify` cannot read a byte, so it can neither prove nor
    /// disprove the key — and the one thing it must not do is call the key
    /// wrong. This is the everyday case for iCloud Drive placeholders and
    /// CloudKit blobs that are not in the cache.
    func testUnreadableMediaIsReportedAsUnverifiedRatherThanWrong() async throws {
        let scenario = try await makeScenario()
        // A file that cannot be probed at all stands in for a placeholder.
        try Data("placeholder".utf8).write(to: scenario.mediaURL)

        do {
            _ = try await MissingKeyEntry(keyManager: scenario.manager)
                .addKey(phraseComponents: foreignPhrase,
                        requiredStampPrefix: scenario.foreignKey.stampPrefix,
                        verify: verifier(for: scenario.mediaURL))
            XCTFail("an unproven key must not be saved")
        } catch let error as MissingKeyEntryError {
            XCTAssertEqual(error, .couldNotVerify,
                           "an unreadable file proves nothing about the key and must not be reported as a wrong key")
        }

        XCTAssertEqual(try scenario.manager.storedKeys().count, 1, "an unproven key must not reach the keychain")
    }

    /// A stamp collision is the only way to be disproved after matching the
    /// fingerprint, and the fingerprint is precisely what cannot distinguish the
    /// two keys. Naming it on both sides of the message rendered "that phrase is
    /// for key X, but this media needs key X".
    func testRejectionAfterAStampMatchDoesNotNameTheSameKeyTwice() async throws {
        let scenario = try await makeScenario()
        let wrongKey = try scenario.manager.deriveKey(from: wrongPhrase, name: AppConstants.defaultKeyName)

        do {
            // Passing the wrong key's own prefix as the requirement makes the
            // stamp pre-check pass, leaving `verify` to do the rejecting.
            _ = try await MissingKeyEntry(keyManager: scenario.manager)
                .addKey(phraseComponents: wrongPhrase,
                        requiredStampPrefix: wrongKey.stampPrefix,
                        verify: verifier(for: scenario.mediaURL))
            XCTFail("a key that does not open the media must be rejected")
        } catch let error as MissingKeyEntryError {
            guard case .wrongKey(let entered, let required) = error else {
                return XCTFail("expected .wrongKey, got \(error)")
            }
            XCTAssertEqual(entered, wrongKey.stampPrefix)
            XCTAssertNil(required, "a fingerprint that matched cannot also be the reason for rejection")
            XCTAssertEqual(error.displayDescription, L10n.MissingKey.wrongKeyUnknown)
        }
    }

    func testEmptyPhraseIsRejectedAsInvalid() async throws {
        let scenario = try await makeScenario()

        do {
            _ = try await MissingKeyEntry(keyManager: scenario.manager)
                .addKey(phraseComponents: [],
                        requiredStampPrefix: scenario.foreignKey.stampPrefix,
                        verify: verifier(for: scenario.mediaURL))
            XCTFail("expected .invalidPhrase")
        } catch let error as MissingKeyEntryError {
            guard case .invalidPhrase = error else {
                return XCTFail("expected .invalidPhrase, got \(error)")
            }
        }
    }
}
