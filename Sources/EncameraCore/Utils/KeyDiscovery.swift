//
//  KeyDiscovery.swift
//  EncameraCore
//
//  Resolves which key encrypted a file (see Documentation/plans/stamp-on-open-local-files.md).
//

import Foundation
import Sodium

/// A confirmed answer to "which key encrypted this file?".
public struct KeyDiscoveryResult: Equatable {
    public let key: PrivateKey
    /// True iff the file's stamp slot already held this key's `stampPrefix` —
    /// the stamping integration uses this to decide whether to (re)write the slot.
    public let stampMatched: Bool
}

/// Why a file did not open, when it did not open.
///
/// Splits the single `nil` that `discoverKey` used to return into the two cases
/// the user needs told apart: "you are missing a key" (actionable — add it) and
/// "these bytes are not readable media" (not actionable by adding a key).
/// Sending someone hunting for a key phrase because their file is damaged is its
/// own harm, so the split is deliberately conservative — see `noKnownKey`.
///
/// How far the split actually reaches: damage that breaks the *structure* is
/// always caught, on every file. Damage confined to the ciphertext body is only
/// caught on a file that names a key this device holds, because AEAD failure is
/// the same event for a wrong key and for altered bytes — the file's own claim
/// about which key wrote it is the only thing that tells them apart. Today that
/// claim is the in-file stamp, and `DiskFileAccess.shouldStampFile` writes it
/// for local files only, so an iCloud Drive file (and any local file not opened
/// since stamping shipped) carries none. Body damage there reports as
/// `noKnownKey`. Widening this needs a trustworthy required-key record for
/// non-local files, not a change to the logic below: the key-UUID xattr does not
/// qualify, since `setKeyUUIDForExistingFiles` speculatively writes the *current*
/// key onto any file missing one, foreign-key media included.
public enum KeyDiscoveryOutcome: Equatable {

    /// A stored key authenticated the first ciphertext block.
    case resolved(KeyDiscoveryResult)

    /// The file parses as encrypted media and has a complete first block, but no
    /// key in the library authenticates it. The overwhelmingly likely cause is a
    /// key this device does not hold — though on an unstamped file this is also
    /// where first-block ciphertext damage lands, since nothing on such a file
    /// names the key that wrote it.
    ///
    /// `requiredStampPrefix` is the file's own stamp when it carries one, for
    /// display via `KeyFingerprint.displayLabel(stampPrefix:)`. An unstamped file
    /// yields nil — the required key is genuinely unknown and must not be named.
    case noKnownKey(requiredStampPrefix: UInt32?)

    /// The bytes are not readable as encrypted media. Either the prologue does
    /// not parse / the first block is incomplete, or the file's own stamp names a
    /// key this device holds and that key still fails to authenticate — which the
    /// AEAD only does when the ciphertext changed under it.
    ///
    /// The second half requires a stamp, so it reaches local files only. See the
    /// note on this enum.
    case unreadable
}

public enum KeyDiscovery: DebugPrintable {

    /// Resolves the key that encrypted the file at `sourceURL`, or nil when no
    /// stored key decrypts it. Never throws; performs no writes (no stamping,
    /// no xattr, no memo — that's the caller's job).
    ///
    /// Callers that need to tell "missing key" from "corrupt file" apart should
    /// use `discoverKeyOutcome` instead; this stays nil-returning so the existing
    /// open paths, which treat both the same, are unaffected.
    ///
    /// Candidate order: stamp matches → xattr hint → current key → remaining
    /// stored keys, deduplicated by uuid. Every candidate — including the
    /// xattr one, which today's open paths trust without verification — is
    /// confirmed by authenticating the first ciphertext block. The file's
    /// prologue and first block are read once; only the AEAD attempt repeats
    /// per candidate.
    public static func discoverKey(for sourceURL: URL, keyManager: KeyManager) async -> KeyDiscoveryResult? {
        await discoverKey(for: sourceURL, keyManager: keyManager, onAttempt: nil)
    }

    /// Internal variant with an attempt observer so tests can assert
    /// candidate ordering.
    static func discoverKey(
        for sourceURL: URL,
        keyManager: KeyManager,
        onAttempt: ((PrivateKey) -> Void)?
    ) async -> KeyDiscoveryResult? {
        guard case .resolved(let result) = await discoverKeyOutcome(for: sourceURL, keyManager: keyManager, onAttempt: onAttempt) else {
            return nil
        }
        return result
    }

    /// The same sweep as `discoverKey`, reporting *why* it failed when it fails.
    ///
    /// Same candidate order, same proof (authenticating the first ciphertext
    /// block), same guarantees: never throws, performs no writes.
    ///
    /// `storedKeysSnapshot` lets a caller sweeping a whole album read the key
    /// library once instead of once per file. `KeychainManager.storedKeys()` is
    /// a `SecItemCopyMatching` over every stored key with `kSecReturnData`, so
    /// on the per-image path it was the single most expensive thing here —
    /// measured at ~0.39ms per call on an iPhone 12 Pro holding ONE key, and it
    /// grows with the library. Pass nil to keep the old read-it-yourself
    /// behavior.
    public static func discoverKeyOutcome(
        for sourceURL: URL,
        keyManager: KeyManager,
        storedKeysSnapshot: [PrivateKey]? = nil
    ) async -> KeyDiscoveryOutcome {
        await discoverKeyOutcome(for: sourceURL,
                                 keyManager: keyManager,
                                 storedKeysSnapshot: storedKeysSnapshot,
                                 onAttempt: nil)
    }

    static func discoverKeyOutcome(
        for sourceURL: URL,
        keyManager: KeyManager,
        storedKeysSnapshot: [PrivateKey]? = nil,
        onAttempt: ((PrivateKey) -> Void)?
    ) async -> KeyDiscoveryOutcome {
        // A file whose prologue does not parse, whose stream header is short, or
        // whose first block is incomplete is not "encrypted with a key we lack" —
        // no key could ever open it. This is the primary corruption signal, and
        // it is structural rather than cryptographic: it does not depend on which
        // keys happen to be in the library.
        guard let probe = FirstBlockProbe(url: sourceURL) else {
            printDebug("discoverKey UNREADABLE url=\(sourceURL.lastPathComponent) reason=prologueOrBlockUnparseable")
            return .unreadable
        }
        let storedKeys = storedKeysSnapshot ?? (try? keyManager.storedKeys()) ?? []
        let stamp = probe.stamp

        var candidates: [PrivateKey] = []
        var seenUUIDs = Set<UUID>()
        func addCandidate(_ key: PrivateKey?) {
            guard let key, seenUUIDs.insert(key.uuid).inserted else {
                return
            }
            candidates.append(key)
        }

        if let stamp {
            // Two of the user's keys can share a stamp prefix (~k²·2⁻³³), so
            // matches are a list, not a single hit.
            for key in storedKeys where key.stampPrefix == stamp {
                addCandidate(key)
            }
        }
        if let xattrUUID = (try? ExtendedAttributesUtil.getKeyUUID(for: sourceURL)) ?? nil {
            // Resolved against `storedKeys` rather than `keyManager.keyWith(uuid:)`,
            // which runs a SECOND full keychain query of its own — two per file on
            // any file carrying the xattr. Beyond being cheaper, this makes both
            // lookups agree by construction: they now read one snapshot instead of
            // two queries taken moments apart. `keyWith` additionally short-circuits
            // to `currentKey` when the app is backgrounded, which loses nothing here
            // because `currentKey` is appended as a candidate immediately below.
            addCandidate(storedKeys.first { $0.uuid == xattrUUID })
        }
        addCandidate(keyManager.currentKey)
        for key in storedKeys {
            addCandidate(key)
        }

        for candidate in candidates {
            onAttempt?(candidate)
            if probe.authenticates(keyBytes: candidate.keyBytes) {
                return .resolved(KeyDiscoveryResult(key: candidate, stampMatched: stamp != nil && stamp == candidate.stampPrefix))
            }
        }

        // Nothing authenticated. Second corruption signal, cryptographic rather
        // than structural: the file's own stamp says "the key that wrote me is
        // the one with this prefix", we hold such a key, and it was tried above
        // and rejected. A correct key only fails to authenticate intact
        // ciphertext if the ciphertext is no longer intact.
        //
        // Unstamped files get no such signal and fall through to `.noKnownKey`.
        // That is every iCloud Drive file today — see the note on
        // `KeyDiscoveryOutcome`.
        //
        // The stamp is a 4-byte prefix, so this misreads a genuine missing-key
        // case as damage if a foreign key collides with a stored one (~2⁻³² per
        // pair). That trade is taken deliberately: in the colliding case the
        // alternative is telling the user to go add a key whose displayed label
        // matches one they already have, which is a dead end either way.
        if let stamp, storedKeys.contains(where: { $0.stampPrefix == stamp }) {
            printDebug("discoverKey UNREADABLE url=\(sourceURL.lastPathComponent) reason=stampedKeyHeldButFailedToAuthenticate")
            return .unreadable
        }

        printDebug("discoverKey NO KNOWN KEY url=\(sourceURL.lastPathComponent) stamped=\(stamp != nil) keysTried=\(candidates.count)")
        return .noKnownKey(requiredStampPrefix: stamp)
    }

    /// Whether the candidate key authenticates the first ciphertext block of
    /// the file. This is the unit of verification for all key discovery: a
    /// bounded read (headers + one ~20KB block) and one AEAD op. Any I/O
    /// error, malformed prologue, or short read returns false — never throws.
    ///
    /// Collapses `.disproved` and `.indeterminate` into a single false, which is
    /// right for the discovery sweep (it moves on to the next candidate either
    /// way) and wrong for anything that reports the result to a user. Those
    /// callers want `proveFirstBlock`.
    public static func canDecryptFirstBlock(of url: URL, with key: PrivateKey) async -> Bool {
        await proveFirstBlock(of: url, with: key) == .proved
    }

    /// The same bounded check as `canDecryptFirstBlock`, keeping "this key is
    /// wrong" and "these bytes could not be read at all" apart.
    public static func proveFirstBlock(of url: URL, with key: PrivateKey) async -> KeyProofOutcome {
        await proveFirstBlockReadingStamp(of: url, with: key).outcome
    }

    /// Both questions the open paths ask about a file, from one read: does this
    /// key authenticate the first block, and what stamp does the file carry.
    ///
    /// Asking them separately — `proveFirstBlock` then
    /// `KeyStampSlot.readStamp(url:)` — opens and re-parses the file twice for
    /// data a single pass already has. `stamp` is nil for an unstamped file and
    /// for one that could not be probed at all.
    public static func proveFirstBlockReadingStamp(
        of url: URL,
        with key: PrivateKey
    ) async -> (outcome: KeyProofOutcome, stamp: UInt32?) {
        guard let probe = FirstBlockProbe(url: url) else {
            return (.indeterminate, nil)
        }
        return (probe.authenticates(keyBytes: key.keyBytes) ? .proved : .disproved, probe.stamp)
    }
}

/// The result of testing one key against one file's first ciphertext block.
///
/// The distinction exists because a bare Bool made an unreadable file look like
/// a wrong key. An iCloud Drive placeholder, a CloudKit blob that is not in the
/// cache yet, and a damaged prologue all fail to probe — and none of them says
/// anything about the key that was passed in.
public enum KeyProofOutcome: Equatable {

    /// The key authenticated the block. Definitive.
    case proved

    /// The block was read and the key failed to authenticate it. Definitive,
    /// short of ciphertext damage.
    case disproved

    /// The block could not be read, so the key was never actually tested.
    case indeterminate
}

/// The stream header and first ciphertext block of an encrypted file, read
/// once so multiple candidate keys can be tried without re-reading the file.
struct FirstBlockProbe {

    /// Upper bound for a plausible first-block length. Both shipped encoders
    /// write 20480-byte plaintext blocks (~20KB ciphertext); anything much
    /// larger means a corrupt block-size field, not a real file.
    private static let maxPlausibleBlockSize: UInt32 = 16 * 1024 * 1024

    let streamHeader: [UInt8]
    let firstBlock: [UInt8]

    /// The file's key stamp, or nil when the slot is zero ("unstamped").
    ///
    /// Read here rather than through `KeyStampSlot.readStamp(url:)` because the
    /// bytes are already in hand: the block-size field is 8 bytes on disk and
    /// bytes 4–7 are the stamp slot, so the probe below parses them out of the
    /// same read. Going back to `readStamp` would re-open the file and re-walk
    /// the prologue to reach a value this initializer already has — one extra
    /// open per file, on a path that runs once per image in the album.
    let stamp: UInt32?

    init?(url: URL) {
        guard let fileHandle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? fileHandle.close() }
        do {
            // Parse the prologue the same way the shipped handlers do:
            // v2 files start with the ENC2 magic and a metadata section to
            // skip; v1 files start directly with the stream header.
            guard let magicData = try fileHandle.read(upToCount: EncryptedFileFormat.magicSize),
                  magicData.count == EncryptedFileFormat.magicSize else {
                return nil
            }
            let contentStart: UInt64
            if Array(magicData) == EncryptedFileFormat.magic {
                try fileHandle.seek(toOffset: UInt64(EncryptedFileFormat.metadataLengthOffset))
                guard let lengthData = try fileHandle.read(upToCount: EncryptedFileFormat.metadataLengthSize),
                      lengthData.count == EncryptedFileFormat.metadataLengthSize else {
                    return nil
                }
                let metadataLength = lengthData.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
                guard metadataLength <= EncryptedFileFormat.maxMetadataSize else {
                    return nil
                }
                contentStart = UInt64(EncryptedFileFormat.metadataLengthOffset + EncryptedFileFormat.metadataLengthSize) + UInt64(metadataLength)
            } else {
                contentStart = 0
            }

            try fileHandle.seek(toOffset: contentStart)
            let headerSize = EncryptedFileFormat.streamHeaderSize
            guard let headerData = try fileHandle.read(upToCount: headerSize),
                  headerData.count == headerSize else {
                return nil
            }

            // Block-size field: 8 bytes on disk, but only bytes 0–3 are the
            // block size — bytes 4–7 are the stamp slot and must be ignored
            // here, exactly as the shipped readers do.
            guard let blockSizeData = try fileHandle.read(upToCount: 8),
                  blockSizeData.count == 8 else {
                return nil
            }
            let blockSize = UInt32(littleEndian: blockSizeData.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
            guard blockSize > 0, blockSize <= Self.maxPlausibleBlockSize else {
                return nil
            }
            let rawStamp = UInt32(littleEndian: blockSizeData.dropFirst(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })

            // The first ciphertext block is exactly blockSize bytes (the
            // encoders record the first block's ciphertext length).
            guard let blockData = try fileHandle.read(upToCount: Int(blockSize)),
                  blockData.count == Int(blockSize) else {
                return nil
            }

            self.streamHeader = Array(headerData)
            self.firstBlock = Array(blockData)
            self.stamp = rawStamp == 0 ? nil : rawStamp
        } catch {
            return nil
        }
    }

    /// Whether the key authenticates the first block.
    ///
    /// initPull succeeds with a WRONG key — only pull authenticates.
    /// Returning true from initPull alone would defeat the whole
    /// verification; the pull below is the proof.
    func authenticates(keyBytes: KeyBytes) -> Bool {
        let sodium = Sodium()
        guard let stream = sodium.secretStream.xchacha20poly1305.initPull(secretKey: keyBytes, header: streamHeader) else {
            return false
        }
        return stream.pull(cipherText: firstBlock) != nil
    }
}
