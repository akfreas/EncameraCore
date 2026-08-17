//
//  KeyEntryValidator.swift
//  EncameraCore
//
//  Fingerprint-gated, additive manual key entry for the returning-user
//  onboarding "I have my key" path (ENC-92, under ENC-75).
//
//  Sibling to `MissingKeyEntry` (ENC-99), but for a different moment: this runs
//  during onboarding, before any media is on disk to decrypt against, so the
//  gate is a full-fingerprint comparison against what the existing-data probe
//  collected (`ExistingDataSummary.requiredFingerprints`) rather than an
//  authenticated decrypt. A mismatch is therefore DETECTABLE up front and
//  reported as such, never surfaced as a generic decrypt failure later.
//

import Foundation

public enum KeyEntryValidationError: Error, ErrorDescribable, Equatable {

    /// The phrase derives a real, well-formed key, but not the one the existing
    /// photos are encrypted with. Both fingerprints are full hex
    /// (`PrivateKey.keychainLabel`); the message renders them via
    /// `KeyFingerprint.displayLabel(fingerprintHex:)`.
    case fingerprintMismatch(entered: String, required: String)

    /// The phrase is not a well-formed key phrase at all (empty, too short a
    /// salt, etc.). Distinct from a fingerprint mismatch: the phrase never
    /// produced a key to compare.
    case invalidPhrase(String)

    public var displayDescription: String {
        switch self {
        case .fingerprintMismatch(let entered, let required):
            return L10n.KeyEntry.fingerprintMismatch(
                KeyFingerprint.displayLabel(fingerprintHex: entered) ?? entered,
                KeyFingerprint.displayLabel(fingerprintHex: required) ?? required
            )
        case .invalidPhrase(let message):
            return message
        }
    }
}

/// Outcome of comparing one key's fingerprint against the fingerprints the
/// existing data needs. The single source of truth for "is this the right key",
/// shared by manual entry (ENC-92) and the guided flip-the-switch flow (ENC-93):
/// the latter verifies a key that ARRIVED via iCloud Keychain rather than one
/// derived from a typed phrase, but the gate is identical.
public enum KeyFingerprintVerification: Equatable {
    /// The fingerprint is among the ones the existing data needs.
    case matched
    /// There were no fingerprints to check against (offline / `.unknown` probe),
    /// so the key is accepted without validation; verification is deferred to
    /// when photos load.
    case unvalidated
    /// A well-formed key that is not one the existing data needs. Both hex
    /// strings are full `PrivateKey.keychainLabel`s.
    case mismatch(entered: String, required: String)
}

/// The result of accepting a manually entered key.
public struct KeyEntryOutcome: Equatable {
    /// The key that was derived and saved.
    public let key: PrivateKey
    /// True when the key was checked against a known fingerprint and matched.
    /// False when no fingerprints were available (offline / `.unknown` probe),
    /// so the key was accepted without validation and verification is deferred
    /// to when photos load.
    public let validatedAgainstFingerprint: Bool
}

/// Derives a phrase's key, validates it against the fingerprints the existing
/// data needs, and — only then — saves it ADDITIVELY as this device's current
/// key.
///
/// Three invariants make this safe:
///
/// 1. **Detectable rejection.** A well-formed phrase that derives the wrong key
///    is rejected with `.fingerprintMismatch` naming both keys, before anything
///    is written. A malformed phrase is rejected with `.invalidPhrase`, a
///    distinct error — the ticket's "wrong key" vs "can't even parse this".
/// 2. **Additive, never overwriting.** `save(key:setNewKeyToCurrent:)` dedupes
///    on key material and keeps every other key in the library (see
///    `KeychainManager.save`). It repoints *which* key is current but never
///    deletes a synchronizable item, so a device that somehow already holds a
///    key retains both.
/// 3. **Offline tolerance.** With no fingerprints to compare against, the key is
///    accepted without validation rather than blocking the user; an
///    authenticated decrypt confirms it when photos load.
public struct KeyEntryValidator {

    private let keyManager: KeyManager

    public init(keyManager: KeyManager) {
        self.keyManager = keyManager
    }

    /// The fingerprint gate, factored out so both the manual-entry path (a key
    /// derived from a typed phrase) and the guided flip-the-switch path (a key
    /// that ARRIVED via iCloud Keychain) apply exactly the same check. Identity
    /// is the full fingerprint (`PrivateKey.keychainLabel`), never the display
    /// name. Leads the mismatch with the primary (most-used) required fingerprint.
    public static func verify(fingerprint entered: String,
                              against requiredFingerprints: [String]) -> KeyFingerprintVerification {
        if requiredFingerprints.isEmpty {
            return .unvalidated
        }
        if requiredFingerprints.contains(entered) {
            return .matched
        }
        return .mismatch(entered: entered, required: requiredFingerprints.first ?? entered)
    }

    /// Derives the phrase, gates it on `requiredFingerprints`, and saves it as
    /// the current key when accepted.
    ///
    /// - Parameters:
    ///   - phraseComponents: the parsed key-phrase words.
    ///   - requiredFingerprints: full fingerprint hex strings
    ///     (`PrivateKey.keychainLabel`) the probe collected, most-used first.
    ///     Empty means the probe could not tell (offline / `.unknown`), in which
    ///     case the key is accepted without validation.
    /// - Note: derivation runs Argon2 (`generateKeyFromPasswordComponentsAndSave`
    ///   / `deriveKey`) and is slow; call this off the main thread.
    @discardableResult
    public func acceptKey(phraseComponents: [String],
                          requiredFingerprints: [String]) throws -> KeyEntryOutcome {

        let candidate: PrivateKey
        do {
            candidate = try keyManager.deriveKey(from: phraseComponents, name: AppConstants.defaultKeyName)
        } catch let error as KeyManagerError {
            // Malformed phrase — never reached the fingerprint comparison.
            throw KeyEntryValidationError.invalidPhrase(error.displayDescription)
        }

        // Identity is the full fingerprint, never the display name — every
        // production key is named `encamera_default_key` (ENC-69).
        let enteredFingerprint = candidate.keychainLabel

        let validated: Bool
        switch KeyEntryValidator.verify(fingerprint: enteredFingerprint, against: requiredFingerprints) {
        case .unvalidated:
            // Offline / `.unknown`: accept without validation. Verification
            // happens when photos load.
            validated = false
        case .matched:
            validated = true
        case let .mismatch(entered, required):
            // Well-formed but wrong: a DETECTABLE mismatch, distinct from a
            // parse error.
            throw KeyEntryValidationError.fingerprintMismatch(entered: entered, required: required)
        }

        // Additive: `save` dedupes on key material and never tombstones another
        // key. `setNewKeyToCurrent: true` makes the returning user's media
        // readable and keeps new photos on the same key across their devices.
        try keyManager.save(key: candidate, setNewKeyToCurrent: true)

        return KeyEntryOutcome(key: candidate, validatedAgainstFingerprint: validated)
    }
}
