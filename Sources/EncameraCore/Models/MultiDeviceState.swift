//
//  MultiDeviceState.swift
//  EncameraCore
//
//  The always-synced multi-device state record (ENC-71 / ENC-80).
//

import Foundation

/// State shared across every device on the iCloud account, persisted as a
/// generic-password keychain item that is written with
/// `kSecAttrSynchronizable = true` **unconditionally** — regardless of the
/// user's key-backup toggle. That is the whole point of the record: a device
/// with key sync off must still learn that this account has used Encamera
/// before, and which devices and keys exist.
///
/// Because it syncs unconditionally, this record is a hard security boundary:
///
/// **No key bytes, no passphrase words, and no password hash may ever be added
/// to this struct.** `keyFingerprints` holds fingerprint hex only — a 16-byte
/// keyed BLAKE2b digest of the key bytes (`KeyFingerprint.fingerprint`), which
/// is not key material and cannot be inverted to recover a key. It exists so
/// the returning-user warning can name a key ("your existing key is 54E0-7B52")
/// and so manually entered keys can be validated offline.
///
/// `MultiDeviceStateTests.testEncodedStateContainsNoSecrets` enforces this by
/// pinning the encoded JSON shape; adding a field will fail that test on
/// purpose, so the addition has to be justified.
public struct MultiDeviceState: Codable, Equatable {

    /// One device that has run Encamera on this iCloud account.
    ///
    /// `deviceID` is the value from `DeviceIDProvider`, which is deliberately
    /// device-local and never migrates. The roster is the separate, synced
    /// structure those IDs are appended into.
    public struct DeviceRecord: Codable, Equatable {
        public let deviceID: String
        public var name: String
        public var lastSeen: Date

        public init(deviceID: String, name: String, lastSeen: Date) {
            self.deviceID = deviceID
            self.name = name
            self.lastSeen = lastSeen
        }
    }

    /// Set once a device completes onboarding. The signal that makes the
    /// returning-user warning fire even when a probe of iCloud storage finds
    /// nothing, e.g. for a user whose media was local-only.
    public var hasUsedEncamera: Bool

    /// Every device known to have run Encamera on this account.
    public var devices: [DeviceRecord]

    /// Lowercase fingerprint hex (`PrivateKey.keychainLabel`). Never key bytes.
    public var keyFingerprints: [String]

    public var hasEvidence: Bool {
        hasUsedEncamera || !devices.isEmpty || !keyFingerprints.isEmpty
    }

    /// Upper bound on the roster, enforced by `merging`. The record lives in a
    /// keychain item that syncs on every write, so it cannot be allowed to grow
    /// without limit as a user cycles through devices. Well above the number of
    /// devices a real person keeps on one iCloud account, and the entries that
    /// get evicted are the ones no UI would name anyway.
    public static let maxDevices = 10

    /// Upper bound on the fingerprint list, enforced by `merging`. The rationale
    /// for `maxDevices` applies verbatim: this record lives in a keychain item that
    /// re-syncs on EVERY authenticated launch (`recordAuthenticatedLaunch`), and
    /// `MultiDeviceStateRecorder.write()` re-adds every stored key's fingerprint on
    /// every call — so an unbounded monotonic union means a user who has imported a
    /// few dozen key phrases over the app's lifetime re-syncs all of them, forever.
    /// Higher than `maxDevices` because a fingerprint is cheap (32 hex characters)
    /// and losing one costs a returning-user validation, whereas evicting a device
    /// only costs a name in a warning string.
    public static let maxKeyFingerprints = 32

    public init(
        hasUsedEncamera: Bool = false,
        devices: [DeviceRecord] = [],
        keyFingerprints: [String] = []
    ) {
        self.hasUsedEncamera = hasUsedEncamera
        self.devices = devices
        self.keyFingerprints = keyFingerprints
    }

    /// Combines a record already in the keychain with one a device wants to
    /// write, so two devices writing concurrently don't clobber each other.
    ///
    /// - `hasUsedEncamera` is sticky: once true on either side it stays true.
    /// - `devices` is a union deduplicated by `deviceID`, keeping the newer
    ///   `lastSeen` (and the name that came with it) for a device present in
    ///   both.
    /// - `keyFingerprints` is an order-preserving union, most-recent-first, then
    ///   capped at `maxKeyFingerprints`.
    /// - the roster is then capped at `maxDevices`, evicting the entries with
    ///   the oldest `lastSeen` so the synced item stays bounded.
    ///
    /// This is a last-writer-merges scheme, not a CRDT: it cannot recover an
    /// entry that iCloud Keychain itself dropped when resolving a conflict
    /// between two full-item writes. It only guarantees that a device reading
    /// then writing never *itself* drops another device's entry.
    public static func merging(existing: MultiDeviceState?, incoming: MultiDeviceState) -> MultiDeviceState {
        var devices: [DeviceRecord] = []
        var indexByDeviceID: [String: Int] = [:]
        for device in (existing?.devices ?? []) + incoming.devices {
            if let index = indexByDeviceID[device.deviceID] {
                if device.lastSeen >= devices[index].lastSeen {
                    devices[index] = device
                }
            } else {
                indexByDeviceID[device.deviceID] = devices.count
                devices.append(device)
            }
        }

        if devices.count > maxDevices {
            // Deterministic even when lastSeen ties, so two devices merging the
            // same pair of records can't disagree about who was evicted.
            let survivors = Set(
                devices
                    .sorted { ($0.lastSeen, $1.deviceID) > ($1.lastSeen, $0.deviceID) }
                    .prefix(maxDevices)
                    .map(\.deviceID)
            )
            devices = devices.filter { survivors.contains($0.deviceID) }
        }

        // Most-recent-first, then capped: `incoming` carries the fingerprints this
        // device is writing now, so it leads and the oldest entries are the ones
        // that fall off the end.
        var fingerprints: [String] = []
        var seenFingerprints: Set<String> = []
        for fingerprint in incoming.keyFingerprints + (existing?.keyFingerprints ?? []) where seenFingerprints.insert(fingerprint).inserted {
            fingerprints.append(fingerprint)
        }
        if fingerprints.count > maxKeyFingerprints {
            fingerprints = Array(fingerprints.prefix(maxKeyFingerprints))
        }

        return MultiDeviceState(
            hasUsedEncamera: (existing?.hasUsedEncamera ?? false) || incoming.hasUsedEncamera,
            devices: devices,
            keyFingerprints: fingerprints
        )
    }
}
