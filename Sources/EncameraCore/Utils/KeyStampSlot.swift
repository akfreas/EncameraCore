//
//  KeyStampSlot.swift
//  EncameraCore
//
//  Key-fingerprint stamp slot in encrypted files (see Documentation/plans/stamp-on-open-local-files.md).
//

import Foundation

/// Reads and writes the 4-byte key-fingerprint stamp inside encrypted files.
///
/// Both the v1 and v2 file formats write the block-size field as 8 bytes but
/// every shipped read path loads only bytes 0–3, so bytes 4–7 are
/// written-as-zero and never read. That dead region is the stamp slot: a
/// routing hint saying "try this key first". A zero slot means "unstamped";
/// proof of key identity is always a successful authenticated decrypt.
public enum KeyStampSlot: DebugPrintable {

    /// The stamp in the file's slot, or nil when the slot is zero
    /// ("unstamped" by convention), the file is too short, has an invalid
    /// layout, or can't be read. Never throws.
    public static func readStamp(url: URL) -> UInt32? {
        guard let fileHandle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? fileHandle.close() }
        guard let offset = stampOffset(in: fileHandle) else {
            return nil
        }
        do {
            try fileHandle.seek(toOffset: offset)
            guard let stampData = try fileHandle.read(upToCount: 4), stampData.count == 4 else {
                return nil
            }
            let stamp = UInt32(littleEndian: stampData.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
            return stamp == 0 ? nil : stamp
        } catch {
            return nil
        }
    }

    /// Writes the stamp into the file's slot, preserving the file's
    /// modification date so gallery sorting never sees a spurious change.
    /// Failures are logged and swallowed — a failed stamp must never fail an
    /// open. No-ops when the slot can't be resolved.
    public static func writeStamp(_ prefix: UInt32, url: URL) {
        let path = url.path
        let modificationDate = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        do {
            let fileHandle = try FileHandle(forUpdating: url)
            defer { try? fileHandle.close() }
            guard let offset = stampOffset(in: fileHandle) else {
                return
            }
            try fileHandle.seek(toOffset: offset)
            try fileHandle.write(contentsOf: withUnsafeBytes(of: prefix.littleEndian) { Data($0) })
        } catch {
            printDebug("Failed to write stamp to \(url.lastPathComponent): \(error)")
            return
        }
        if let modificationDate {
            do {
                try FileManager.default.setAttributes([.modificationDate: modificationDate], ofItemAtPath: path)
            } catch {
                printDebug("Failed to restore modification date on \(url.lastPathComponent): \(error)")
            }
        }
    }

    /// Byte offset of the stamp slot (bytes 4–7 of the block-size field), or
    /// nil when the file is too short, has an invalid layout, or can't be
    /// opened. Never throws — callers treat nil as "no slot".
    static func stampOffset(for url: URL) -> UInt64? {
        guard let fileHandle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? fileHandle.close() }
        return stampOffset(in: fileHandle)
    }

    static func stampOffset(in fileHandle: FileHandle) -> UInt64? {
        do {
            let fileSize = try fileHandle.seekToEnd()
            try fileHandle.seek(toOffset: 0)
            guard let magicData = try fileHandle.read(upToCount: EncryptedFileFormat.magicSize),
                  magicData.count == EncryptedFileFormat.magicSize else {
                return nil
            }

            // ENC3: stamp lives at byte 44 — the first 4 bytes of the
            // 32-byte AAD-excluded mutable plaintext block.
            if Array(magicData) == SeekableEncryptedHeader.magic {
                let stampFileOffset: UInt64 = 44
                guard fileSize >= stampFileOffset + 4 else { return nil }
                return stampFileOffset
            }

            // Offset of the block-size field's unused bytes 4–7, relative to
            // the start of the v1-compatible content (stream header + block size).
            let slotOffsetInContent = UInt64(EncryptedFileFormat.streamHeaderSize + 4)

            let offset: UInt64
            if Array(magicData) == EncryptedFileFormat.magic {
                // V2: magic + version + flags + metadataLength, then metadata,
                // then the v1-compatible content.
                try fileHandle.seek(toOffset: UInt64(EncryptedFileFormat.metadataLengthOffset))
                guard let lengthData = try fileHandle.read(upToCount: EncryptedFileFormat.metadataLengthSize),
                      lengthData.count == EncryptedFileFormat.metadataLengthSize else {
                    return nil
                }
                let metadataLength = lengthData.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
                guard metadataLength <= EncryptedFileFormat.maxMetadataSize else {
                    return nil
                }
                let contentStart = UInt64(EncryptedFileFormat.metadataLengthOffset + EncryptedFileFormat.metadataLengthSize) + UInt64(metadataLength)
                offset = contentStart + slotOffsetInContent
            } else {
                // V1: the file starts directly with the stream header.
                offset = slotOffsetInContent
            }

            guard fileSize >= offset + 4 else {
                return nil
            }
            return offset
        } catch {
            return nil
        }
    }
}
