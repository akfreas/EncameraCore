import XCTest
@testable import EncameraCore

/// Fingerprint-gated, additive manual key entry for the returning-user
/// onboarding "I have my key" path (ENC-92).
final class KeyEntryValidationTests: XCTestCase {

    /// The device's own key, present before entry in the additive test.
    private let deviceKey = PrivateKey(name: AppConstants.defaultKeyName,
                                       keyBytes: Array(repeating: 0x42, count: 32),
                                       creationDate: Date(timeIntervalSince1970: 0))

    private let correctPhrase = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot"]
    private let wrongPhrase = ["zulu", "yankee", "xray", "whiskey", "victor", "uniform"]

    /// The fingerprint (full hex) a phrase derives to under the given manager —
    /// the same derivation `acceptKey` uses, so a match is by construction.
    private func fingerprint(of phrase: [String], manager: KeyManager) throws -> String {
        try manager.deriveKey(from: phrase, name: AppConstants.defaultKeyName).keychainLabel
    }

    // MARK: - Tests

    /// The correct phrase derives the fingerprint the photos need, is accepted as
    /// validated, and becomes the current key.
    func testCorrectPhraseProducesMatchingFingerprint() throws {
        let manager = DemoKeyManager()
        let required = try fingerprint(of: correctPhrase, manager: manager)

        let outcome = try KeyEntryValidator(keyManager: manager)
            .acceptKey(phraseComponents: correctPhrase, requiredFingerprints: [required])

        XCTAssertTrue(outcome.validatedAgainstFingerprint,
                      "a known-fingerprint match must report as validated")
        XCTAssertEqual(outcome.key.keychainLabel, required)
        XCTAssertEqual(manager.currentKey?.keychainLabel, required,
                       "the accepted key becomes current so the user's media is readable")
        XCTAssertTrue(try manager.storedKeys().contains { $0.keychainLabel == required })
    }

    /// A well-formed but wrong phrase is a DETECTABLE mismatch — reported as a
    /// fingerprint-specific error naming both keys, before anything is saved.
    func testWrongPhraseProducesFingerprintMismatch() throws {
        let manager = DemoKeyManager()
        let required = try fingerprint(of: correctPhrase, manager: manager)
        let enteredExpected = try fingerprint(of: wrongPhrase, manager: manager)

        do {
            _ = try KeyEntryValidator(keyManager: manager)
                .acceptKey(phraseComponents: wrongPhrase, requiredFingerprints: [required])
            XCTFail("a non-matching key must be rejected")
        } catch let error as KeyEntryValidationError {
            guard case .fingerprintMismatch(let entered, let requiredReported) = error else {
                return XCTFail("expected .fingerprintMismatch, got \(error)")
            }
            XCTAssertEqual(entered, enteredExpected)
            XCTAssertEqual(requiredReported, required)
            XCTAssertNotEqual(entered, requiredReported)
            // Specific, not generic: the message names both keys' short labels.
            XCTAssertTrue(error.displayDescription.contains(KeyFingerprint.displayLabel(fingerprintHex: required)!),
                          "the mismatch must name the key the photos actually need")
        }

        XCTAssertTrue(try manager.storedKeys().allSatisfy { $0.keychainLabel != enteredExpected },
                      "a rejected key must not reach the keychain")
    }

    /// A malformed phrase (nothing to derive) is rejected with a parse error that
    /// is a DIFFERENT case from a fingerprint mismatch.
    func testMalformedPhraseIsDistinctFromMismatch() throws {
        let manager = DemoKeyManager()
        let required = try fingerprint(of: correctPhrase, manager: manager)

        do {
            _ = try KeyEntryValidator(keyManager: manager)
                .acceptKey(phraseComponents: [], requiredFingerprints: [required])
            XCTFail("a malformed phrase must be rejected")
        } catch let error as KeyEntryValidationError {
            guard case .invalidPhrase = error else {
                return XCTFail("expected .invalidPhrase, got \(error) — a parse failure must be distinct from a mismatch")
            }
        }

        XCTAssertEqual(try manager.storedKeys().count, 0,
                       "a malformed phrase must not reach the keychain")
    }

    /// Entry is additive: the library grows, the device's own key survives, and
    /// nothing is overwritten.
    func testEntryIsAdditive() throws {
        let manager = DemoKeyManager(keys: [deviceKey])
        manager.currentKey = deviceKey
        let required = try fingerprint(of: correctPhrase, manager: manager)
        XCTAssertEqual(try manager.storedKeys().count, 1)

        _ = try KeyEntryValidator(keyManager: manager)
            .acceptKey(phraseComponents: correctPhrase, requiredFingerprints: [required])

        XCTAssertEqual(try manager.storedKeys().count, 2, "the library grew rather than being replaced")
        XCTAssertTrue(try manager.storedKeys().contains { $0.keyBytes == deviceKey.keyBytes },
                      "accepting a key must never drop the device's own key")
        XCTAssertTrue(try manager.storedKeys().contains { $0.keychainLabel == required },
                      "the entered key was added")
    }

    /// Offline / `.unknown` probe: with no fingerprints to compare against, the
    /// key is accepted without validation rather than blocking the user.
    func testValidationSkippedWhenNoFingerprintsKnown() throws {
        let manager = DemoKeyManager()

        let outcome = try KeyEntryValidator(keyManager: manager)
            .acceptKey(phraseComponents: correctPhrase, requiredFingerprints: [])

        XCTAssertFalse(outcome.validatedAgainstFingerprint,
                       "with no known fingerprints the key is accepted unvalidated")
        XCTAssertEqual(manager.currentKey?.keychainLabel, outcome.key.keychainLabel,
                       "the key is still saved and made current")
        XCTAssertEqual(try manager.storedKeys().count, 1)
    }

    // MARK: - Shared fingerprint gate (reused by ENC-93's guided flow)

    /// `KeyEntryValidator.verify` is the single fingerprint gate shared by manual
    /// entry (a derived key) and the guided flip-the-switch flow (a key that
    /// ARRIVED via iCloud Keychain). Its three outcomes must be exactly matched /
    /// unvalidated / mismatch, so both callers agree on what "the right key" is.
    func testVerifyMatchesUnvalidatedAndMismatch() {
        let a = String(repeating: "a", count: 32)
        let b = String(repeating: "b", count: 32)

        XCTAssertEqual(KeyEntryValidator.verify(fingerprint: a, against: [a, b]), .matched,
                       "a fingerprint present in the required set matches")
        XCTAssertEqual(KeyEntryValidator.verify(fingerprint: a, against: []), .unvalidated,
                       "no required fingerprints means accept-unvalidated (offline/unknown)")
        XCTAssertEqual(KeyEntryValidator.verify(fingerprint: a, against: [b]),
                       .mismatch(entered: a, required: b),
                       "a well-formed but absent fingerprint is a mismatch, leading with the primary required key")
    }
}
