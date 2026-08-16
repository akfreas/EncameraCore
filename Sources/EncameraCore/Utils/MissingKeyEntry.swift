//
//  MissingKeyEntry.swift
//  EncameraCore
//
//  Additive, fingerprint-gated key entry for media this device cannot open
//  (ENC-99, under the ENC-76 failsafe).
//

import Foundation

public extension Notification.Name {
    /// Posted when a decrypt-only key is added to the library (ENC-99).
    ///
    /// An added, non-current key does NOT go through `setActiveKey`, so it never
    /// fires `keyPublisher` and none of the rebuild that ENC-97 relies on for an
    /// *imported* key happens here. Nothing needs rebuilding either — the key
    /// library is read fresh on every `storedKeys()` call, `DiskFileAccess`'s
    /// memo only ever caches successful resolutions, and `KeyDiscovery` sweeps
    /// the whole library on each open. What does need redoing is work whose
    /// *result* was computed while the key was absent: the album reconcile, whose
    /// locked-out count is now stale.
    static let keyLibraryDidGrow = Notification.Name("EncameraKeyLibraryDidGrow")
}

public enum MissingKeyEntryError: Error, ErrorDescribable, Equatable {

    /// The phrase derives a real key, but not the one this media needs.
    /// `required` is nil when the media never named a key — the phrase was
    /// rejected by the decrypt proof rather than by a fingerprint comparison.
    case wrongKey(entered: UInt32, required: UInt32?)

    /// The key could not be tested, because nothing in the album was readable:
    /// an iCloud Drive album of placeholders, or CloudKit blobs not yet in the
    /// cache. Distinct from `wrongKey` on purpose — the phrase may well be
    /// right, and telling someone their correct key is wrong is worse than
    /// telling them to try again once the media has downloaded.
    case couldNotVerify

    /// The derived key is already in this device's library, so adding it cannot
    /// be what is stopping the media from opening.
    case alreadyHeld

    /// The phrase is not a well-formed key phrase at all.
    case invalidPhrase(String)

    public var displayDescription: String {
        switch self {
        case .wrongKey(let entered, let required):
            guard let required else {
                return L10n.MissingKey.wrongKeyUnknown
            }
            return L10n.MissingKey.wrongKey(
                KeyFingerprint.displayLabel(stampPrefix: entered),
                KeyFingerprint.displayLabel(stampPrefix: required)
            )
        case .couldNotVerify:
            return L10n.MissingKey.couldNotVerify
        case .alreadyHeld:
            return L10n.MissingKey.alreadyHaveKey
        case .invalidPhrase(let message):
            return message
        }
    }
}

/// Adds a key to the library for the sole purpose of decrypting existing media.
///
/// Two invariants make this safe to expose next to a locked photo:
///
/// 1. **The key is never promoted.** `save(key:setNewKeyToCurrent:)` is called
///    with `false`, so new media keeps being encrypted with this device's own
///    key. The added key is decrypt-only, exactly as ENC-76 specifies.
/// 2. **The key must actually be the right one.** The stamp prefix is only a
///    fast pre-check; the accept/reject decision rests on `verify`, an
///    authenticated decrypt of the media itself. Nothing is written to the
///    keychain until that proof succeeds.
public struct MissingKeyEntry {

    private let keyManager: KeyManager

    public init(keyManager: KeyManager) {
        self.keyManager = keyManager
    }

    /// Derives the phrase's key, proves it opens the media, and only then saves
    /// it as a decrypt-only library entry.
    ///
    /// - Parameters:
    ///   - requiredStampPrefix: the stamp the media carries, when it carries
    ///     one. Used solely to reject early and to word the error; a nil value
    ///     weakens the message, never the gate.
    ///   - verify: authenticated proof that this key opens the media in
    ///     question — in production `KeyDiscovery.proveFirstBlock`. Tri-state
    ///     rather than Bool: "no readable file to test against" has to stay
    ///     apart from "this key does not open it".
    @discardableResult
    public func addKey(
        phraseComponents: [String],
        requiredStampPrefix: UInt32?,
        verify: (PrivateKey) async -> KeyProofOutcome
    ) async throws -> PrivateKey {

        let candidate: PrivateKey
        do {
            candidate = try keyManager.deriveKey(from: phraseComponents, name: AppConstants.defaultKeyName)
        } catch let error as KeyManagerError {
            throw MissingKeyEntryError.invalidPhrase(error.displayDescription)
        }

        // Identity is the full fingerprint, never the display name — every
        // production key is named `encamera_default_key` (ENC-69).
        let alreadyHeld = ((try? keyManager.storedKeys()) ?? [])
            .contains { $0.keychainLabel == candidate.keychainLabel }
        if alreadyHeld {
            throw MissingKeyEntryError.alreadyHeld
        }

        // Cheap rejection on the 4-byte stamp before spending an AEAD op. A
        // prefix collision slips through here and is caught by `verify` below,
        // which is why the stamp is a pre-check and not the gate.
        if let requiredStampPrefix, candidate.stampPrefix != requiredStampPrefix {
            throw MissingKeyEntryError.wrongKey(entered: candidate.stampPrefix, required: requiredStampPrefix)
        }

        switch await verify(candidate) {
        case .proved:
            break
        case .indeterminate:
            throw MissingKeyEntryError.couldNotVerify
        case .disproved:
            // `required` is deliberately dropped when the stamp already matched:
            // the pre-check above proved `candidate.stampPrefix ==
            // requiredStampPrefix`, so naming both would render "that phrase is
            // for key 54E0-7B52, but this media needs key 54E0-7B52". Reaching
            // here past a stamp match means a 4-byte prefix collision, and the
            // fingerprint is exactly the thing that cannot tell the two apart.
            throw MissingKeyEntryError.wrongKey(entered: candidate.stampPrefix, required: nil)
        }

        // Decrypt-only: `false` is the whole point of this call site.
        try keyManager.save(key: candidate, setNewKeyToCurrent: false)
        NotificationCenter.default.post(name: .keyLibraryDidGrow, object: nil)
        return candidate
    }
}
