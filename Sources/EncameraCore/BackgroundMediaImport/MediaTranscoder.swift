//
//  MediaTranscoder.swift
//  EncameraCore
//
//  Normalizes arbitrary picker-selected media into the formats the import
//  pipeline stores natively (JPEG for images, MOV for videos) before encryption.
//  This mirrors the invariant the Photos path already enforces in
//  `MediaLoaderService` by renaming loaded files to `.jpeg`/`.mov`, so anything
//  the document picker can offer (GIF, WebP, HEIF, TIFF, DNG, BMP, AVIF, M4V, …)
//  can actually be imported instead of failing with `.unknownMediaType`.
//

import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum MediaTranscoderError: Error {
    /// The OS could not decode the source image/video for transcoding.
    case undecodable(underlying: Error?)
    /// A transcode output could not be written.
    case writeFailed
    /// The video export session failed for every attempted preset.
    case exportFailed(underlying: Error?)
    /// The file is neither a decodable image nor a video.
    case unsupportedType(ext: String)
}

/// Converts non-native media formats to the pipeline's native formats. Native
/// formats are passed through untouched so already-supported imports stay
/// bit-identical to before.
public struct MediaTranscoder {

    /// Image formats stored natively — passed through without re-encoding.
    static let nativeImageExtensions: Set<String> = ["jpeg", "jpg", "png", "heic"]
    /// Video formats stored natively — passed through without re-muxing.
    static let nativeVideoExtensions: Set<String> = ["mov", "mp4"]

    public init() {}

    /// Returns a URL and `MediaType` suitable for the import pipeline. Native
    /// formats are returned unchanged; everything else is transcoded into
    /// `URL.tempMediaDirectory` so existing temp-file cleanup covers it.
    public func normalizeForImport(url: URL, storageType: StorageType? = .cloudKit) async throws -> (url: URL, mediaType: MediaType) {
        let ext = url.pathExtension.lowercased()
        let utType = UTType(filenameExtension: ext)

        if Self.nativeImageExtensions.contains(ext) {
            return (url, .photo)
        }
        if Self.nativeVideoExtensions.contains(ext) {
            // Native videos normally pass through untouched, but a video headed
            // for the seekable ENC3 format must be faststart first — see
            // `faststartForChunkingIfNeeded`.
            return (await faststartForChunkingIfNeeded(url: url, storageType: storageType), .video)
        }

        // Decide by UTType conformance rather than the extension whitelist.
        if let utType, utType.conforms(to: .image) {
            return (try transcodeImageToJPEG(source: url), .photo)
        }
        if let utType, utType.conforms(to: .movie) || utType.conforms(to: .video) {
            return (try await transcodeVideoToMOV(source: url), .video)
        }

        // Unknown/mislabeled extension: sniff the content as an image first.
        if let jpeg = try? transcodeImageToJPEG(source: url) {
            return (jpeg, .photo)
        }
        throw MediaTranscoderError.unsupportedType(ext: ext)
    }

    // MARK: - Faststart normalization

    /// Puts the container's `moov` atom at the front of a video that is about to
    /// be written as chunked ENC3 — a passthrough remux, no re-encode.
    ///
    /// Faststart is a precondition for chunked streaming, not an optimization:
    /// with the index at the tail, AVFoundation's first read of the file is its
    /// LAST chunk, and ready-before-downloaded degrades badly. Videos below the
    /// chunking threshold (or with the toggle off) pass through untouched, and a
    /// failed remux falls back to the original bytes — a tail-`moov` video still
    /// plays, it just streams worse.
    public func faststartForChunkingIfNeeded(url: URL, storageType: StorageType? = .cloudKit) async -> URL {
        let size = url.fileSizeBytes() ?? 0
        guard VideoChunkingPolicy.shouldWriteSeekableFormat(
            mediaType: .video,
            plaintextLength: size,
            storageType: storageType
        ) else { return url }

        guard let export = AVAssetExportSession(asset: AVURLAsset(url: url),
                                                presetName: AVAssetExportPresetPassthrough) else {
            return url
        }
        do {
            let outputURL = try makeTempURL(extension: "mov")
            export.outputURL = outputURL
            export.outputFileType = .mov
            export.shouldOptimizeForNetworkUse = true
            try await runExport(export)
            return outputURL
        } catch {
            debugPrint("faststartForChunkingIfNeeded remux failed, keeping original: \(error)")
            return url
        }
    }

    // MARK: - Image transcoding

    /// Decodes any ImageIO-readable image and re-encodes it as JPEG, copying the
    /// source image properties so EXIF orientation and creation date survive.
    private func transcodeImageToJPEG(source: URL) throws -> URL {
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
              CGImageSourceGetCount(imageSource) > 0,
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            throw MediaTranscoderError.undecodable(underlying: nil)
        }

        // Preserve metadata (EXIF/TIFF orientation, creation date, GPS, …).
        let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any] ?? [:]

        let outputURL = try makeTempURL(extension: "jpeg")
        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw MediaTranscoderError.writeFailed
        }

        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw MediaTranscoderError.writeFailed
        }
        return outputURL
    }

    // MARK: - Video transcoding

    /// Remuxes (or, if that fails, re-encodes) a non-native video into a MOV.
    private func transcodeVideoToMOV(source: URL) async throws -> URL {
        let asset = AVURLAsset(url: source)
        // Passthrough remuxes without re-encoding when the codecs are compatible;
        // fall back to a re-encode preset when passthrough can't produce a MOV.
        let presets = [AVAssetExportPresetPassthrough, AVAssetExportPresetHighestQuality]

        var lastError: Error?
        for preset in presets {
            guard let export = AVAssetExportSession(asset: asset, presetName: preset) else { continue }
            let outputURL = try makeTempURL(extension: "mov")
            export.outputURL = outputURL
            export.outputFileType = .mov
            // Put the `moov` atom at the front ("faststart"). Without it AVFoundation's
            // very first read of a MOV is near the END of the file, because that is
            // where the index lives. For a chunk-streamed video that turns the opening
            // frame into a seek to the last chunk; for a whole-file download it means
            // nothing can start until everything has arrived.
            export.shouldOptimizeForNetworkUse = true

            do {
                try await runExport(export)
                return outputURL
            } catch {
                lastError = error
                try? FileManager.default.removeItem(at: outputURL)
            }
        }
        throw MediaTranscoderError.exportFailed(underlying: lastError)
    }

    private func runExport(_ export: AVAssetExportSession) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            export.exportAsynchronously {
                switch export.status {
                case .completed:
                    continuation.resume()
                default:
                    continuation.resume(throwing: MediaTranscoderError.exportFailed(underlying: export.error))
                }
            }
        }
    }

    // MARK: - Helpers

    private func makeTempURL(extension ext: String) throws -> URL {
        let directory = URL.tempMediaDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
    }
}
