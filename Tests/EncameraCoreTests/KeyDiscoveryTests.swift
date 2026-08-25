import XCTest
@testable import EncameraCore

final class KeyDiscoveryTests: XCTestCase {

    private var tempDirectory: URL!
    private let keyA = PrivateKey(name: "keyA", keyBytes: Array(repeating: 0x42, count: 32), creationDate: Date(timeIntervalSince1970: 0))
    private let keyB = PrivateKey(name: "keyB", keyBytes: Array(repeating: 0x24, count: 32), creationDate: Date(timeIntervalSince1970: 0))

    /// Multi-block plaintext so the first block is a full 20480-byte block.
    private let plaintext = Data((0..<50000).map { UInt8($0 % 251) })

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeyDiscoveryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    private func encryptV2Fixture(with key: PrivateKey, name: String = "fixture-v2") async throws -> URL {
        let cleartext = CleartextMedia(source: plaintext, mediaType: .photo, id: name)
        let url = tempDirectory.appendingPathComponent("\(name).encifile")
        let handler = SecretFileHandlerV2(keyBytes: key.keyBytes, source: cleartext, targetURL: url)
        _ = try await handler.encryptWithMetadata(EncryptedFileMetadata())
        return url
    }

    private func encryptV1Fixture(with key: PrivateKey, name: String = "fixture-v1") async throws -> URL {
        let cleartext = CleartextMedia(source: plaintext, mediaType: .photo, id: name)
        let url = tempDirectory.appendingPathComponent("\(name).encifile")
        let handler = SecretFileHandler(keyBytes: key.keyBytes, source: cleartext, targetURL: url)
        _ = try await handler.encrypt()
        return url
    }

    /// Byte range of the first ciphertext block, parsed out of the file's own
    /// prologue. The damage sites below anchor on this rather than on an offset
    /// from the end of the file, so a change to the metadata section or the
    /// block size moves them with the layout instead of sliding them into the
    /// header.
    private func firstBlockRange(of url: URL) throws -> Range<Int> {
        let data = try Data(contentsOf: url)
        var contentStart = 0
        if Array(data.prefix(EncryptedFileFormat.magicSize)) == EncryptedFileFormat.magic {
            let lengthStart = EncryptedFileFormat.metadataLengthOffset
            let metadataLength = data[lengthStart..<(lengthStart + EncryptedFileFormat.metadataLengthSize)]
                .withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            contentStart = lengthStart + EncryptedFileFormat.metadataLengthSize + Int(metadataLength)
        }
        // Block-size field: 8 bytes, of which bytes 0-3 are the size and 4-7
        // are the stamp slot.
        let blockSizeStart = contentStart + EncryptedFileFormat.streamHeaderSize
        let blockSize = Int(data[blockSizeStart..<(blockSizeStart + 4)]
            .withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
        let blockStart = blockSizeStart + 8
        XCTAssertGreaterThan(blockSize, 512, "fixture must carry a full first block")
        XCTAssertLessThanOrEqual(blockStart + blockSize, data.count, "the first block must lie inside the file")
        return blockStart..<(blockStart + blockSize)
    }

    /// Flips 200 bytes inside the first ciphertext block's body, leaving the
    /// prologue, stream header, block-size field and stamp slot intact.
    private func damageFirstBlockBody(of url: URL) throws {
        let range = try firstBlockRange(of: url)
        var fileData = try Data(contentsOf: url)
        for index in (range.lowerBound + 64)..<(range.lowerBound + 264) {
            fileData[index] ^= 0xFF
        }
        try fileData.write(to: url)
    }

    /// Cuts the file mid-way through its first ciphertext block: headers
    /// survive, but there is no complete block left to authenticate.
    private func truncateMidFirstBlock(of url: URL) throws {
        let range = try firstBlockRange(of: url)
        let fileData = try Data(contentsOf: url)
        try fileData.prefix(range.lowerBound + range.count / 2).write(to: url)
    }

    // MARK: - canDecryptFirstBlock

    func testFirstBlockDecryptSucceedsWithCorrectKeyV2() async throws {
        let url = try await encryptV2Fixture(with: keyA)
        let result = await KeyDiscovery.canDecryptFirstBlock(of: url, with: keyA)
        XCTAssertTrue(result)
    }

    func testFirstBlockDecryptSucceedsWithCorrectKeyV1() async throws {
        let url = try await encryptV1Fixture(with: keyA)
        let result = await KeyDiscovery.canDecryptFirstBlock(of: url, with: keyA)
        XCTAssertTrue(result)
    }

    func testFirstBlockDecryptFailsWithWrongKey() async throws {
        // Regression guard for the initPull-vs-pull subtlety: initPull
        // succeeds with a wrong key, so an implementation that skips the pull
        // would wrongly return true here.
        let v2URL = try await encryptV2Fixture(with: keyA)
        let v2Control = await KeyDiscovery.proveFirstBlock(of: v2URL, with: keyA)
        XCTAssertEqual(v2Control, .proved, "the encrypting key must open the v2 fixture")
        let v2Proof = await KeyDiscovery.proveFirstBlock(of: v2URL, with: keyB)
        XCTAssertEqual(v2Proof, .disproved, "the wrong key must be rejected, not read as an unreadable file")
        let v2Result = await KeyDiscovery.canDecryptFirstBlock(of: v2URL, with: keyB)
        XCTAssertFalse(v2Result)

        let v1URL = try await encryptV1Fixture(with: keyA)
        let v1Control = await KeyDiscovery.proveFirstBlock(of: v1URL, with: keyA)
        XCTAssertEqual(v1Control, .proved, "the encrypting key must open the v1 fixture")
        let v1Proof = await KeyDiscovery.proveFirstBlock(of: v1URL, with: keyB)
        XCTAssertEqual(v1Proof, .disproved, "the wrong key must be rejected, not read as an unreadable file")
        let v1Result = await KeyDiscovery.canDecryptFirstBlock(of: v1URL, with: keyB)
        XCTAssertFalse(v1Result)
    }

    func testFirstBlockDecryptIgnoresStampSlot() async throws {
        let url = try await encryptV2Fixture(with: keyA)
        KeyStampSlot.writeStamp(0xFFFFFFFF, url: url)

        let rightKey = await KeyDiscovery.canDecryptFirstBlock(of: url, with: keyA)
        XCTAssertTrue(rightKey)
        let wrongKey = await KeyDiscovery.canDecryptFirstBlock(of: url, with: keyB)
        XCTAssertFalse(wrongKey)
    }

    func testFirstBlockDecryptFalseOnTruncatedFile() async throws {
        let url = try await encryptV2Fixture(with: keyA)
        let intact = await KeyDiscovery.proveFirstBlock(of: url, with: keyA)
        XCTAssertEqual(intact, .proved, "the fixture must authenticate before it is truncated")

        try truncateMidFirstBlock(of: url)

        let proof = await KeyDiscovery.proveFirstBlock(of: url, with: keyA)
        XCTAssertEqual(proof, .indeterminate, "an incomplete block is unreadable, not a rejected key")
        let result = await KeyDiscovery.canDecryptFirstBlock(of: url, with: keyA)
        XCTAssertFalse(result)
    }

    func testFirstBlockDecryptFalseOnGarbageAndMissingFiles() async throws {
        let readableURL = try await encryptV2Fixture(with: keyA, name: "readable-anchor")
        let readableResult = await KeyDiscovery.canDecryptFirstBlock(of: readableURL, with: keyA)
        XCTAssertTrue(readableResult, "anchor: the same call returns true on readable media")

        let garbageURL = tempDirectory.appendingPathComponent("garbage.enc")
        try? Data("definitely not an encrypted file".utf8).write(to: garbageURL)
        let garbageResult = await KeyDiscovery.canDecryptFirstBlock(of: garbageURL, with: keyA)
        XCTAssertFalse(garbageResult)
        let garbageProof = await KeyDiscovery.proveFirstBlock(of: garbageURL, with: keyA)
        XCTAssertEqual(garbageProof, .indeterminate, "the key was never tested against these bytes")

        let emptyURL = tempDirectory.appendingPathComponent("empty.enc")
        try? Data().write(to: emptyURL)
        let emptyResult = await KeyDiscovery.canDecryptFirstBlock(of: emptyURL, with: keyA)
        XCTAssertFalse(emptyResult)
        let emptyProof = await KeyDiscovery.proveFirstBlock(of: emptyURL, with: keyA)
        XCTAssertEqual(emptyProof, .indeterminate)

        let missingURL = tempDirectory.appendingPathComponent("missing.enc")
        let missingResult = await KeyDiscovery.canDecryptFirstBlock(of: missingURL, with: keyA)
        XCTAssertFalse(missingResult)
        let missingProof = await KeyDiscovery.proveFirstBlock(of: missingURL, with: keyA)
        XCTAssertEqual(missingProof, .indeterminate)
    }

    // MARK: - discoverKey

    private func discoverRecordingAttempts(
        url: URL,
        keyManager: KeyManager
    ) async -> (result: KeyDiscoveryResult?, attempts: [String]) {
        var attempts: [String] = []
        let result = await KeyDiscovery.discoverKey(for: url, keyManager: keyManager, onAttempt: { attempts.append($0.name) })
        return (result, attempts)
    }

    func testStampMatchWinsFirst() async throws {
        let keyC = PrivateKey(name: "keyC", keyBytes: Array(repeating: 0x77, count: 32), creationDate: Date(timeIntervalSince1970: 0))
        let url = try await encryptV2Fixture(with: keyB)
        KeyStampSlot.writeStamp(keyB.stampPrefix, url: url)

        let keyManager = DemoKeyManager(keys: [keyA, keyB, keyC])
        keyManager.currentKey = keyA

        let (result, attempts) = await discoverRecordingAttempts(url: url, keyManager: keyManager)
        XCTAssertEqual(attempts, ["keyB"], "A stamped file must resolve with exactly one test-decrypt attempt")
        XCTAssertEqual(result?.key, keyB)
        XCTAssertEqual(result?.stampMatched, true)
    }

    func testStaleStampFallsThrough() async throws {
        let url = try await encryptV2Fixture(with: keyB)
        KeyStampSlot.writeStamp(keyA.stampPrefix, url: url)

        let keyManager = DemoKeyManager(keys: [keyA, keyB])
        keyManager.currentKey = keyA

        let (result, attempts) = await discoverRecordingAttempts(url: url, keyManager: keyManager)
        XCTAssertEqual(attempts, ["keyA", "keyB"], "Stale stamp candidate rejected by pull, then the sweep finds the real key")
        XCTAssertEqual(result?.key, keyB)
        XCTAssertEqual(result?.stampMatched, false)
    }

    func testXattrConfirmedNotTrusted() async throws {
        // Behavior change vs. today's open paths: the xattr is a hint that
        // gets test-decrypted, not trusted.
        let url = try await encryptV2Fixture(with: keyB)
        try ExtendedAttributesUtil.setKeyUUID(keyA.uuid, for: url)

        let keyManager = DemoKeyManager(keys: [keyA, keyB])
        keyManager.currentKey = keyA

        let (result, attempts) = await discoverRecordingAttempts(url: url, keyManager: keyManager)
        XCTAssertEqual(attempts, ["keyA", "keyB"])
        XCTAssertEqual(result?.key, keyB)
        XCTAssertEqual(result?.stampMatched, false)
    }

    func testCurrentKeyBeforeRemainingKeys() async throws {
        let keyC = PrivateKey(name: "keyC", keyBytes: Array(repeating: 0x77, count: 32), creationDate: Date(timeIntervalSince1970: 0))
        let url = try await encryptV2Fixture(with: keyB)

        let keyManager = DemoKeyManager(keys: [keyA, keyB, keyC])
        keyManager.currentKey = keyC

        let (result, attempts) = await discoverRecordingAttempts(url: url, keyManager: keyManager)
        XCTAssertEqual(attempts, ["keyC", "keyA", "keyB"], "No hints: current key first, then remaining stored keys in order")
        XCTAssertEqual(result?.key, keyB)
    }

    func testStampCollisionTriesAllMatches() async throws {
        // Two real keys whose BLAKE2b stamp prefixes collide, found by
        // deterministic brute-force over sha256("collision-search-<i>")
        // (~58k candidates — the 4-byte prefix birthday-bounds at ~2^16).
        let collidingBytes1 = KeyDiscoveryTests.bytes(fromHex: "e1b33d369bf555406f9956543d5b0ae0581a6501cfc70d33c3ff0b64346a1b61")
        let collidingBytes2 = KeyDiscoveryTests.bytes(fromHex: "d0213432d6b5707cd28d27ae4dac8a94c6c18e6c626bcfda3c16be3cf35cb683")
        let collider1 = PrivateKey(name: "collider1", keyBytes: collidingBytes1, creationDate: Date(timeIntervalSince1970: 0))
        let collider2 = PrivateKey(name: "collider2", keyBytes: collidingBytes2, creationDate: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(collider1.stampPrefix, collider2.stampPrefix, "Fixture keys must share a stamp prefix")
        XCTAssertNotEqual(collider1.keyBytes, collider2.keyBytes)

        let url = try await encryptV2Fixture(with: collider2)
        KeyStampSlot.writeStamp(collider2.stampPrefix, url: url)

        let keyManager = DemoKeyManager(keys: [collider1, collider2])
        keyManager.currentKey = nil

        let (result, attempts) = await discoverRecordingAttempts(url: url, keyManager: keyManager)
        XCTAssertEqual(attempts, ["collider1", "collider2"], "Both stamp matches tried in stored-key order")
        XCTAssertEqual(result?.key, collider2)
        XCTAssertEqual(result?.stampMatched, true)
    }

    func testNilWhenNoKeyDecrypts() async throws {
        let unstoredKey = PrivateKey(name: "unstored", keyBytes: Array(repeating: 0x99, count: 32), creationDate: Date(timeIntervalSince1970: 0))
        let url = try await encryptV2Fixture(with: unstoredKey)

        let keyManager = DemoKeyManager(keys: [keyA, keyB])
        keyManager.currentKey = keyA

        let result = await KeyDiscovery.discoverKey(for: url, keyManager: keyManager)
        XCTAssertNil(result)

        // The same file and the same call resolve once the library holds the
        // key it was encrypted with, so the nil above is a missing key rather
        // than a fixture that never opened.
        let withKey = DemoKeyManager(keys: [keyA, keyB, unstoredKey])
        withKey.currentKey = keyA
        let found = await KeyDiscovery.discoverKey(for: url, keyManager: withKey)
        XCTAssertEqual(found?.key.keyBytes, unstoredKey.keyBytes)
    }

    func testDiscoverKeyNilOnCorruptFile() async throws {
        let url = tempDirectory.appendingPathComponent("corrupt.enc")
        try Data("garbage".utf8).write(to: url)

        let keyManager = DemoKeyManager(keys: [keyA])
        keyManager.currentKey = keyA

        let result = await KeyDiscovery.discoverKey(for: url, keyManager: keyManager)
        XCTAssertNil(result)
        let outcome = await KeyDiscovery.discoverKeyOutcome(for: url, keyManager: keyManager)
        XCTAssertEqual(outcome, .unreadable, "bytes that are not media are damage, not a missing key")

        // Anchor: the same key manager and the same call resolve readable media.
        let readableURL = try await encryptV2Fixture(with: keyA, name: "corrupt-anchor")
        let readable = await KeyDiscovery.discoverKey(for: readableURL, keyManager: keyManager)
        XCTAssertEqual(readable?.key, keyA)
    }

    /// The failsafe end to end (ENC-97): after a key phrase import replaces the
    /// current key, the retained key is still in `storedKeys()` and discovery
    /// sweeps it, so media encrypted under it opens with no user interaction.
    /// Both keys carry the same display name, exactly as in production.
    func testMediaFromRetainedKeyStillDiscoverable() async throws {
        let retained = PrivateKey(name: "encamera_default_key", keyBytes: Array(repeating: 0x42, count: 32), creationDate: Date(timeIntervalSince1970: 0))
        let imported = PrivateKey(name: "encamera_default_key", keyBytes: Array(repeating: 0x24, count: 32), creationDate: Date(timeIntervalSince1970: 1))
        let url = try await encryptV2Fixture(with: retained, name: "retained-key-media")

        // Post-import state: the imported key is current, the replaced one is
        // retained decrypt-only in the library.
        let keyManager = DemoKeyManager(keys: [imported, retained])
        keyManager.currentKey = imported

        let result = await KeyDiscovery.discoverKey(for: url, keyManager: keyManager)
        XCTAssertEqual(result?.key.keyBytes, retained.keyBytes, "media under the retained key must still resolve")

        // And it would not without retention.
        let withoutRetained = DemoKeyManager(keys: [imported])
        withoutRetained.currentKey = imported
        let missing = await KeyDiscovery.discoverKey(for: url, keyManager: withoutRetained)
        XCTAssertNil(missing, "guards the assertion above against passing for the wrong reason")
    }

    // MARK: - Missing key vs. corruption (ENC-99)

    /// The heart of ENC-99. `testNilWhenNoKeyDecrypts` and
    /// `testDiscoverKeyNilOnCorruptFile` above both get nil from `discoverKey`;
    /// the whole point of the outcome API is that they must not be the same
    /// answer, because one is fixable by adding a key and the other is not.
    func testMissingKeyIsDistinctFromCorruption() async throws {
        let keyManager = DemoKeyManager(keys: [keyA, keyB])
        keyManager.currentKey = keyA

        // Case 1: intact media, encrypted with a key the device does not hold.
        let unstoredKey = PrivateKey(name: "unstored", keyBytes: Array(repeating: 0x99, count: 32), creationDate: Date(timeIntervalSince1970: 0))
        let foreignURL = try await encryptV2Fixture(with: unstoredKey, name: "foreign")
        let foreignOutcome = await KeyDiscovery.discoverKeyOutcome(for: foreignURL, keyManager: keyManager)
        XCTAssertEqual(foreignOutcome, .noKnownKey(requiredStampPrefix: nil))

        // Case 2: bytes that are not encrypted media at all.
        let corruptURL = tempDirectory.appendingPathComponent("corrupt.enc")
        try Data("garbage".utf8).write(to: corruptURL)
        let corruptOutcome = await KeyDiscovery.discoverKeyOutcome(for: corruptURL, keyManager: keyManager)
        XCTAssertEqual(corruptOutcome, .unreadable)

        XCTAssertNotEqual(foreignOutcome, corruptOutcome, "the two nil cases must now be distinguishable")

        // And the nil-returning API is unchanged for both, so existing callers
        // that don't care about the reason keep their behavior.
        let foreignLegacy = await KeyDiscovery.discoverKey(for: foreignURL, keyManager: keyManager)
        let corruptLegacy = await KeyDiscovery.discoverKey(for: corruptURL, keyManager: keyManager)
        XCTAssertNil(foreignLegacy)
        XCTAssertNil(corruptLegacy)
    }

    /// A truncated file — headers intact, first block incomplete — is damage,
    /// not a missing key. Adding a key would never open it, so telling the user
    /// to go find one would send them after something that cannot help.
    func testTruncatedMediaIsUnreadableNotMissingKey() async throws {
        let url = try await encryptV2Fixture(with: keyA, name: "truncated")
        let keyManager = DemoKeyManager(keys: [keyA, keyB])
        keyManager.currentKey = keyA

        let intact = await KeyDiscovery.discoverKeyOutcome(for: url, keyManager: keyManager)
        XCTAssertEqual(intact, .resolved(KeyDiscoveryResult(key: keyA, stampMatched: false)),
                       "the fixture must open before it is truncated")

        try truncateMidFirstBlock(of: url)

        let outcome = await KeyDiscovery.discoverKeyOutcome(for: url, keyManager: keyManager)
        XCTAssertEqual(outcome, .unreadable)
    }

    /// The cryptographic corruption signal: the file's own stamp names a key we
    /// hold, and that key still fails to authenticate. A correct key only fails
    /// on ciphertext that changed, so this is damage rather than a missing key.
    func testStampedFileWithHeldKeyThatFailsIsUnreadable() async throws {
        let url = try await encryptV2Fixture(with: keyA, name: "damaged-block")
        KeyStampSlot.writeStamp(keyA.stampPrefix, url: url)

        let keyManager = DemoKeyManager(keys: [keyA, keyB])
        keyManager.currentKey = keyA

        let intact = await KeyDiscovery.discoverKeyOutcome(for: url, keyManager: keyManager)
        XCTAssertEqual(intact, .resolved(KeyDiscoveryResult(key: keyA, stampMatched: true)),
                       "the fixture must open, by its own stamp, before its block is damaged")

        try damageFirstBlockBody(of: url)

        // The structural producer of `.unreadable` is excluded here: the file
        // still parses, it still names keyA, and keyA — which the library holds
        // — is now rejected by the AEAD rather than never tested.
        XCTAssertNotNil(FirstBlockProbe(url: url), "the prologue and block layout must survive the damage")
        XCTAssertEqual(KeyStampSlot.readStamp(url: url), keyA.stampPrefix, "the stamp must survive the damage")
        let proof = await KeyDiscovery.proveFirstBlock(of: url, with: keyA)
        XCTAssertEqual(proof, .disproved, "the damage must be cryptographic, not structural")

        let outcome = await KeyDiscovery.discoverKeyOutcome(for: url, keyManager: keyManager)
        XCTAssertEqual(outcome, .unreadable, "stamp names a key we hold and it fails: damage, not a missing key")
    }

    /// The boundary of the cryptographic damage signal, pinned so it is not
    /// mistaken for a guarantee. The same damaged fixture as
    /// `testStampedFileWithHeldKeyThatFailsIsUnreadable`, minus the stamp:
    /// nothing on the file names the key that wrote it, AEAD failure looks
    /// identical to a wrong key, and the outcome is `noKnownKey`.
    ///
    /// This is not a hypothetical shape — `DiskFileAccess.shouldStampFile`
    /// excludes every iCloud Drive file, so it is the state of all of them.
    func testUnstampedDamagedBlockIsIndistinguishableFromAMissingKey() async throws {
        let url = try await encryptV2Fixture(with: keyA, name: "damaged-block-unstamped")
        XCTAssertNil(KeyStampSlot.readStamp(url: url), "the fixture must carry no stamp")

        try damageFirstBlockBody(of: url)

        let keyManager = DemoKeyManager(keys: [keyA, keyB])
        keyManager.currentKey = keyA

        let outcome = await KeyDiscovery.discoverKeyOutcome(for: url, keyManager: keyManager)
        XCTAssertEqual(outcome, .noKnownKey(requiredStampPrefix: nil),
                       "without a stamp there is nothing to tell damage from a foreign key; the split does not reach here")
    }

    /// The required fingerprint comes from the stamp slot when the file carries
    /// one, so the UI can name the key the user has to go find.
    func testRequiredFingerprintReportedFromStamp() async throws {
        let unstoredKey = PrivateKey(name: "unstored", keyBytes: Array(repeating: 0x99, count: 32), creationDate: Date(timeIntervalSince1970: 0))
        let url = try await encryptV2Fixture(with: unstoredKey, name: "stamped-foreign")
        KeyStampSlot.writeStamp(unstoredKey.stampPrefix, url: url)

        let keyManager = DemoKeyManager(keys: [keyA, keyB])
        keyManager.currentKey = keyA

        let outcome = await KeyDiscovery.discoverKeyOutcome(for: url, keyManager: keyManager)
        XCTAssertEqual(outcome, .noKnownKey(requiredStampPrefix: unstoredKey.stampPrefix))

        // And it renders as the short display label the UI shows.
        guard case .noKnownKey(let prefix) = outcome, let prefix else {
            return XCTFail("expected a reported fingerprint")
        }
        XCTAssertEqual(KeyFingerprint.displayLabel(stampPrefix: prefix),
                       KeyFingerprint.displayLabel(stampPrefix: unstoredKey.stampPrefix))
    }

    /// An unstamped foreign file yields no fingerprint. The required key is
    /// genuinely unknown and must not be invented.
    func testUnstampedForeignMediaReportsNoFingerprint() async throws {
        let unstoredKey = PrivateKey(name: "unstored", keyBytes: Array(repeating: 0x99, count: 32), creationDate: Date(timeIntervalSince1970: 0))
        let url = try await encryptV2Fixture(with: unstoredKey, name: "unstamped-foreign")
        XCTAssertNil(KeyStampSlot.readStamp(url: url), "the fixture must carry no stamp")

        let keyManager = DemoKeyManager(keys: [keyA])
        keyManager.currentKey = keyA

        let outcome = await KeyDiscovery.discoverKeyOutcome(for: url, keyManager: keyManager)
        XCTAssertEqual(outcome, .noKnownKey(requiredStampPrefix: nil))

        // Read against a working stamp path in the same run: the same foreign
        // key, stamped, is reported. The nil above is an absent stamp, not a
        // stamp-blind probe.
        let stampedURL = try await encryptV2Fixture(with: unstoredKey, name: "unstamped-foreign-anchor")
        KeyStampSlot.writeStamp(unstoredKey.stampPrefix, url: stampedURL)
        let stampedOutcome = await KeyDiscovery.discoverKeyOutcome(for: stampedURL, keyManager: keyManager)
        XCTAssertEqual(stampedOutcome, .noKnownKey(requiredStampPrefix: unstoredKey.stampPrefix))
    }

    private static func bytes(fromHex hex: String) -> KeyBytes {
        stride(from: 0, to: hex.count, by: 2).map { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            let end = hex.index(start, offsetBy: 2)
            return UInt8(hex[start..<end], radix: 16)!
        }
    }

    func testFirstBlockDecryptReadsBoundedBytes() async throws {
        // Proxy for the bounded-read guarantee: corrupt every byte after the
        // first ciphertext block. If the implementation read beyond the first
        // block, authentication of later data would fail — the first block
        // alone must decide the result.
        let url = try await encryptV2Fixture(with: keyA)
        let firstBlockEnd = try firstBlockRange(of: url).upperBound
        var fileData = try Data(contentsOf: url)
        XCTAssertLessThan(firstBlockEnd, fileData.count, "the fixture must have bytes past the first block to corrupt")
        for index in firstBlockEnd..<fileData.count {
            fileData[index] ^= 0xFF
        }
        try fileData.write(to: url)

        let result = await KeyDiscovery.canDecryptFirstBlock(of: url, with: keyA)
        XCTAssertTrue(result)
    }

    // MARK: - Probe-read stamp equivalence

    /// `FirstBlockProbe` parses the stamp out of the block-size field it already
    /// reads, so discovery no longer re-opens the file via
    /// `KeyStampSlot.readStamp`. The two must agree on every shape of file, or
    /// the stamp-based routing and the corruption/missing-key split shift
    /// underneath us.
    func testProbeStampMatchesKeyStampSlotForStampedAndUnstamped() async throws {
        for (label, makeURL) in [
            ("v2", { try await self.encryptV2Fixture(with: self.keyA, name: "probe-stamp-v2") }),
            ("v1", { try await self.encryptV1Fixture(with: self.keyA, name: "probe-stamp-v1") })
        ] as [(String, () async throws -> URL)] {
            let url = try await makeURL()

            // Unstamped: both must report nil, not 0.
            XCTAssertNil(KeyStampSlot.readStamp(url: url), "\(label) precondition: fixture starts unstamped")
            XCTAssertNil(FirstBlockProbe(url: url)?.stamp, "\(label) probe must report an unstamped file as nil")

            // Stamped: both must report the same value.
            KeyStampSlot.writeStamp(keyA.stampPrefix, url: url)
            XCTAssertEqual(FirstBlockProbe(url: url)?.stamp,
                           KeyStampSlot.readStamp(url: url),
                           "\(label) probe stamp must equal KeyStampSlot.readStamp")
            XCTAssertEqual(FirstBlockProbe(url: url)?.stamp, keyA.stampPrefix,
                           "\(label) probe stamp must be the value that was written")

            // A stamp is not allowed to disturb the block the AEAD reads.
            let stillDecrypts = await KeyDiscovery.canDecryptFirstBlock(of: url, with: keyA)
            XCTAssertTrue(stillDecrypts, "\(label) stamping must not corrupt the first block")
        }
    }

    /// An injected snapshot must produce the same outcome as letting discovery
    /// query the key manager itself — that equivalence is the whole basis for
    /// hoisting the keychain read out of the per-image loop.
    func testInjectedStoredKeysSnapshotMatchesSelfQuery() async throws {
        let keyC = PrivateKey(name: "keyC", keyBytes: Array(repeating: 0x77, count: 32), creationDate: Date(timeIntervalSince1970: 0))
        let url = try await encryptV2Fixture(with: keyB, name: "snapshot-equiv")
        let keyManager = DemoKeyManager(keys: [keyA, keyB, keyC])
        keyManager.currentKey = keyA

        let selfQueried = await KeyDiscovery.discoverKeyOutcome(for: url, keyManager: keyManager)
        let injected = await KeyDiscovery.discoverKeyOutcome(for: url,
                                                            keyManager: keyManager,
                                                            storedKeysSnapshot: try keyManager.storedKeys())
        XCTAssertEqual(selfQueried, injected)
        guard case .resolved(let resolved) = injected else {
            return XCTFail("expected the encrypting key to be discovered, got \(injected)")
        }
        XCTAssertEqual(resolved.key.uuid, keyB.uuid)
    }

    /// A snapshot that omits the encrypting key must report the missing-key
    /// outcome rather than silently falling back to a fresh keychain read.
    func testInjectedSnapshotIsAuthoritativeOverKeyManager() async throws {
        let url = try await encryptV2Fixture(with: keyB, name: "snapshot-authoritative")
        let keyManager = DemoKeyManager(keys: [keyA, keyB])
        keyManager.currentKey = keyA

        let outcome = await KeyDiscovery.discoverKeyOutcome(for: url,
                                                           keyManager: keyManager,
                                                           storedKeysSnapshot: [keyA])
        guard case .noKnownKey = outcome else {
            return XCTFail("a snapshot without the encrypting key must report noKnownKey, got \(outcome)")
        }
    }

    /// The xattr hint must be tried BEFORE the current key. Isolated here by
    /// naming a key that is not the current one, so attempt order is the only
    /// thing that can distinguish the hint being honored from the sweep
    /// stumbling onto the right key anyway. This replaces the call-count proxy
    /// `DiskFileAccessTests` used before discovery stopped resolving the hint
    /// through `keyManager.keyWith(uuid:)`.
    func testXattrHintOrderedBeforeCurrentKey() async throws {
        let keyC = PrivateKey(name: "keyC", keyBytes: Array(repeating: 0x77, count: 32), creationDate: Date(timeIntervalSince1970: 0))
        let url = try await encryptV2Fixture(with: keyC, name: "xattr-order")
        try ExtendedAttributesUtil.setKeyUUID(keyB.uuid, for: url)

        let keyManager = DemoKeyManager(keys: [keyA, keyB, keyC])
        keyManager.currentKey = keyA

        let (result, attempts) = await discoverRecordingAttempts(url: url, keyManager: keyManager)
        XCTAssertEqual(attempts.first, "keyB", "the xattr-named key must be tried first, ahead of the current key")
        XCTAssertEqual(attempts, ["keyB", "keyA", "keyC"])
        XCTAssertEqual(result?.key, keyC)
    }
}
