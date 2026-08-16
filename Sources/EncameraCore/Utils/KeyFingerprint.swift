//
//  KeyFingerprint.swift
//  EncameraCore
//
//  Deterministic key identity for stamp-on-open (see Documentation/plans/stamp-on-open-local-files.md).
//

import Foundation
import Sodium

/// Derives a deterministic fingerprint from raw key bytes.
///
/// The fingerprint is a routing hint, not proof of identity — proof is always a
/// successful authenticated decrypt. Unlike `PrivateKey.uuid` (minted at save
/// time), the fingerprint is a pure function of the key bytes, so the same key
/// produces the same fingerprint on every device, across re-derivations and
/// key-phrase imports.
public enum KeyFingerprint {

    // FROZEN PERSISTENCE FORMAT: this constant, the BLAKE2b algorithm, and the
    // 16-byte output length are persisted inside encrypted files on disk (the
    // stamp slot). Never change any of them — stamped files would silently
    // degrade to hint-miss/rediscovery. Must be exactly 16 bytes.
    private static let domainSeparation = Data("encamera.keyfp.1".utf8)

    private static let sodium = Sodium()

    /// 16-byte BLAKE2b keyed hash of the key bytes, domain-separated from all
    /// other `genericHash` uses in the app.
    public static func fingerprint(keyBytes: KeyBytes) -> Data {
        precondition(domainSeparation.count == 16, "Domain separation constant must be exactly 16 bytes")
        guard let hash = sodium.genericHash.hash(
            message: keyBytes,
            key: [UInt8](domainSeparation),
            outputLength: 16
        ) else {
            fatalError("BLAKE2b hashing cannot fail for valid parameters")
        }
        return Data(hash)
    }

    /// First 4 bytes of the fingerprint, little-endian. This is the value
    /// written into the file stamp slot; `0` is reserved to mean "unstamped".
    public static func stampPrefix(keyBytes: KeyBytes) -> UInt32 {
        let fingerprint = fingerprint(keyBytes: keyBytes)
        return UInt32(littleEndian: fingerprint.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
    }

    /// The stamp prefix as uppercase hex in two hyphen-separated groups of
    /// four, in on-disk byte order (little-endian bytes of the `UInt32`, i.e.
    /// fingerprint bytes 0–3), so the label matches the fingerprint hex
    /// byte-for-byte and is identical for the same key on every device.
    public static func displayLabel(stampPrefix: UInt32) -> String {
        let hex = withUnsafeBytes(of: stampPrefix.littleEndian) { bytes in
            bytes.map { String(format: "%02X", $0) }.joined()
        }
        return "\(hex.prefix(4))-\(hex.suffix(4))"
    }

    /// The same short label derived from a full fingerprint hex string
    /// (`PrivateKey.keychainLabel`). Used where only the fingerprint is known
    /// and the key bytes are not — e.g. a fingerprint read from the synced
    /// `MultiDeviceState` record, which by design never carries key material.
    ///
    /// `keychainLabel` is lowercase hex of the fingerprint bytes in order, and
    /// `displayLabel(stampPrefix:)` renders bytes 0–3 in that same order, so
    /// taking the first eight hex characters produces an identical label.
    public static func displayLabel(fingerprintHex: String) -> String? {
        let hex = fingerprintHex.prefix(8).uppercased()
        guard hex.count == 8, hex.allSatisfy(\.isHexDigit) else {
            return nil
        }
        return "\(hex.prefix(4))-\(hex.suffix(4))"
    }
}

/// Resolves the human-readable key identity shown in the media info sheet.
///
/// Display-only: one bounded stamp read plus an in-memory scan of stored
/// keys. No discovery, no test-decrypts, no writes — the label must never
/// make opening the info sheet slower or mutate anything.
public enum KeyFingerprintDisplay {

    /// The label for the file's stamp, or nil when the file is unstamped or
    /// unreadable. Exactly one stored key matching the stamp yields
    /// "keyA (54E0-7B52)"; zero or several matches yield bare "54E0-7B52".
    ///
    /// The stamp is only a 4-byte prefix, so two distinct keys can collide on it.
    /// Naming one of them would assert an identity the stamp cannot prove, so an
    /// ambiguous match deliberately falls back to bare hex.
    public static func label(for url: URL, storedKeys: [PrivateKey]) -> String? {
        guard let stamp = KeyStampSlot.readStamp(url: url) else {
            return nil
        }
        let hex = KeyFingerprint.displayLabel(stampPrefix: stamp)
        let matches = storedKeys.filter { $0.stampPrefix == stamp }
        // Only an UNAMBIGUOUS match may be named. The stamp is a 4-byte routing
        // hint, not proof of ownership, so two stored keys can share one — and
        // naming a key the file may not actually belong to is worse than naming
        // none, because the label is what a user reaches for when deciding which
        // key to keep.
        guard matches.count == 1, let match = matches.first else {
            return hex
        }
        return "\(match.name) (\(hex))"
    }
}

public extension PrivateKey {
    var fingerprint: Data { KeyFingerprint.fingerprint(keyBytes: keyBytes) }
    var stampPrefix: UInt32 { KeyFingerprint.stampPrefix(keyBytes: keyBytes) }
}
