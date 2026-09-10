//
//  DuplicateMediaUtil.swift
//  EncameraCore
//
//  Created for duplicate media detection feature.
//

import Foundation
import Sodium
import CryptoKit

/// Detects duplicate imported media within an album using two strategies:
/// - V2 files: Compare `sourceAssetIdentifier` from embedded metadata
/// - V1 files: Partial decrypt + hash of the first content block
public struct DuplicateMediaUtil {

    /// A group of media items that share the same content source
    public struct DuplicateGroup: Sendable {
        /// The identifier used to group (sourceAssetIdentifier or content hash)
        public let groupKey: String
        /// How the duplicate was detected
        public let detectionMethod: DetectionMethod
        /// The duplicate media items (2+)
        public let items: [MediaWithMetadata<EncryptedMedia>]
    }

    public enum DetectionMethod: Sendable {
        /// V2 files matched by PHAsset localIdentifier
        case sourceAssetIdentifier
        /// V1 files matched by partial content hash
        case contentHash
    }

    // MARK: - V2 Duplicate Detection (sourceAssetIdentifier)

    /// Finds duplicates among files by comparing `sourceAssetIdentifier` from embedded metadata.
    /// Items with nil `sourceAssetIdentifier` are excluded.
    public static func findDuplicatesBySourceId(
        in mediaWithMetadata: [MediaWithMetadata<EncryptedMedia>]
    ) -> [DuplicateGroup] {
        var groups: [String: [MediaWithMetadata<EncryptedMedia>]] = [:]

        for item in mediaWithMetadata {
            guard let sourceId = item.metadata?.sourceAssetIdentifier else {
                continue
            }
            groups[sourceId, default: []].append(item)
        }

        return groups.compactMap { key, items in
            let uniqueMediaIds = Set(items.map { $0.media.id })
            guard uniqueMediaIds.count >= 2 else { return nil }
            return DuplicateGroup(
                groupKey: key,
                detectionMethod: .sourceAssetIdentifier,
                items: items
            )
        }
    }

    // MARK: - V1 Duplicate Detection (partial decrypt + hash)

    /// Finds duplicates among files lacking `sourceAssetIdentifier` by partially
    /// decrypting each file and comparing content hashes.
    /// Decrypts only the first content block of each file.
    public static func findDuplicatesByContentHash(
        in mediaWithMetadata: [MediaWithMetadata<EncryptedMedia>],
        keyBytes: [UInt8]
    ) async -> [DuplicateGroup] {
        var hashToItems: [String: [MediaWithMetadata<EncryptedMedia>]] = [:]

        for item in mediaWithMetadata {
            guard let url = item.media.url else { continue }

            if let hash = partialContentHash(for: url, keyBytes: keyBytes) {
                hashToItems[hash, default: []].append(item)
            }
        }

        return hashToItems.compactMap { key, items in
            guard items.count >= 2 else { return nil }
            return DuplicateGroup(
                groupKey: key,
                detectionMethod: .contentHash,
                items: items
            )
        }
    }

    // MARK: - Combined

    /// Finds all duplicates in an album using both detection methods.
    /// V2 files with `sourceAssetIdentifier` → identifier comparison.
    /// Remaining files without `sourceAssetIdentifier` → partial decrypt + content hash.
    public static func findAllDuplicates(
        in mediaWithMetadata: [MediaWithMetadata<EncryptedMedia>],
        keyBytes: [UInt8]
    ) async -> [DuplicateGroup] {
        // Phase 1: Find duplicates by sourceAssetIdentifier
        let sourceIdGroups = findDuplicatesBySourceId(in: mediaWithMetadata)

        // Collect IDs of items already matched by sourceAssetIdentifier
        let matchedMediaIds = Set(sourceIdGroups.flatMap { $0.items.map { $0.media.id } })

        // Phase 2: For remaining items without sourceAssetIdentifier, use content hash
        let unmatchedItems = mediaWithMetadata.filter { item in
            item.metadata?.sourceAssetIdentifier == nil && !matchedMediaIds.contains(item.media.id)
        }

        let contentHashGroups = await findDuplicatesByContentHash(
            in: unmatchedItems,
            keyBytes: keyBytes
        )

        return sourceIdGroups + contentHashGroups
    }

    // MARK: - Private Helpers

    /// Partially decrypts an encrypted file and returns a SHA-256 hash of the first decrypted block.
    /// Returns nil if the file cannot be read or decrypted.
    private static func partialContentHash(for url: URL, keyBytes: [UInt8]) -> String? {
        // ENC3 (chunked video) is per-chunk AEAD, not a secretstream — the block
        // machinery below cannot read it. Those files are ≥50 MiB videos whose
        // imports are matched by sourceAssetIdentifier in phase 1; skipping the
        // content-hash fallback for them loses nothing that phase caught.
        guard !SeekableEncryptedHeader.isSeekableFormat(fileURL: url) else { return nil }
        do {
            let metadataHandler = EncryptedMetadataHandler()
            let contentOffset = try metadataHandler.contentOffset(for: url)

            let fileHandle = try FileHandle(forReadingFrom: url)
            defer { try? fileHandle.close() }

            // Seek to content start
            try fileHandle.seek(toOffset: contentOffset)

            // Read 24-byte stream header
            guard let headerData = try fileHandle.read(upToCount: 24),
                  headerData.count == 24 else {
                return nil
            }
            let streamHeader = Array(headerData)

            // Read block size (8 bytes, use first 4 as UInt32)
            guard let blockSizeData = try fileHandle.read(upToCount: 8),
                  blockSizeData.count == 8 else {
                return nil
            }
            let blockSize: UInt32 = blockSizeData.withUnsafeBytes { $0.load(as: UInt32.self) }

            // Initialize decryption stream
            let sodium = Sodium()
            guard let streamDec = sodium.secretStream.xchacha20poly1305.initPull(
                secretKey: keyBytes,
                header: streamHeader
            ) else {
                return nil
            }

            // Read and decrypt the first block
            guard let encryptedBlock = try fileHandle.read(upToCount: Int(blockSize)),
                  !encryptedBlock.isEmpty else {
                return nil
            }

            guard let (decryptedBytes, _) = streamDec.pull(cipherText: Array(encryptedBlock)) else {
                return nil
            }

            // Hash the decrypted content
            let hash = SHA256.hash(data: Data(decryptedBytes))
            return hash.map { String(format: "%02x", $0) }.joined()
        } catch {
            return nil
        }
    }
}
