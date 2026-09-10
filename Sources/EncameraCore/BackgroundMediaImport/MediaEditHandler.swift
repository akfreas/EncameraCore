//
//  MediaEditHandler.swift
//  EncameraCore
//

import Foundation
import Combine
import UIKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// Handles editing (rotating) encrypted media: decrypt → rotate → re-encrypt → replace original.
/// Uses BackgroundTaskManager for task state management.
@MainActor
public class MediaEditHandler: DebugPrintable {

    // MARK: - Dependencies

    private let taskManager: BackgroundTaskManager
    private var albumManager: AlbumManaging?

    // MARK: - Private Properties

    private var activeBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var cancellables = Set<AnyCancellable>()
    private var currentEditTask: Task<Void, Error>?
    private var exportSession: AVAssetExportSession?

    // MARK: - Initialization

    public init(taskManager: BackgroundTaskManager = .shared) {
        self.taskManager = taskManager
    }

    // MARK: - Public Configuration

    public func configure(albumManager: AlbumManaging) {
        self.albumManager = albumManager
    }

    // MARK: - Public Edit API

    /// Start editing (rotating) a media item.
    /// - Parameters:
    ///   - media: The encrypted media to edit
    ///   - rotationAngle: Rotation in degrees (90, 180, 270)
    ///   - album: The album the media belongs to
    ///   - progressHandler: Optional callback for progress updates suitable for OperationProgressView
    @discardableResult
    public func startEdit(
        media: InteractableMedia<EncryptedMedia>,
        rotationAngle: Int,
        album: Album,
        progressHandler: ((EditProgressPhase) -> Void)? = nil
    ) async throws -> String {
        guard let albumManager = albumManager else {
            throw BackgroundImportError.configurationError
        }

        let task = createAndRegisterTask(media: media, rotationAngle: rotationAngle)
        return try await executeEditTask(task, album: album, albumManager: albumManager, progressHandler: progressHandler)
    }

    // MARK: - Task Creation

    private func createAndRegisterTask(
        media: InteractableMedia<EncryptedMedia>,
        rotationAngle: Int
    ) -> EditTask {
        let taskId = UUID().uuidString

        let task = EditTask(
            id: taskId,
            mediaToEdit: media,
            rotationAngle: rotationAngle
        )

        taskManager.addTask(task)

        taskManager.registerCancellationHandler(for: taskId) { [weak self] in
            self?.printDebug("Cancellation handler invoked for edit task: \(taskId)")
            self?.exportSession?.cancelExport()
            self?.currentEditTask?.cancel()
        }

        printDebug("Created edit task with ID: \(taskId)")
        return task
    }

    // MARK: - Edit Execution

    private func executeEditTask(
        _ task: EditTask,
        album: Album,
        albumManager: AlbumManaging,
        progressHandler: ((EditProgressPhase) -> Void)?
    ) async throws -> String {
        taskManager.markTaskRunning(taskId: task.id)
        startBackgroundTask()
        taskManager.resetTimeEstimationState()

        currentEditTask = Task {
            let fileAccess = await InteractableMediaFileAccess(for: album, albumManager: albumManager)
            try await performEdit(task: task, fileAccess: fileAccess, album: album, progressHandler: progressHandler)
        }

        do {
            try await currentEditTask!.value
            await MainActor.run {
                self.taskManager.finalizeTaskCompleted(taskId: task.id, totalItems: 1)
                self.endBackgroundTask()
            }
        } catch is CancellationError {
            await MainActor.run {
                self.printDebug("Edit was cancelled")
                self.taskManager.finalizeTaskCancelled(taskId: task.id)
                self.endBackgroundTask()
            }
            throw CancellationError()
        } catch {
            await MainActor.run {
                self.taskManager.finalizeTaskFailed(taskId: task.id, error: error)
                self.endBackgroundTask()
            }
            throw error
        }

        return task.id
    }

    private func performEdit(
        task: EditTask,
        fileAccess: InteractableMediaFileAccess,
        album: Album,
        progressHandler: ((EditProgressPhase) -> Void)?
    ) async throws {
        let media = task.mediaToEdit
        let rotationAngle = task.rotationAngle
        let startTime = Date()

        // Read the original's embedded metadata up front (best-effort) so the
        // rotated replacement keeps its capture date — and, crucially, so the
        // save below runs the metadata-bearing V2 writer: with a nil metadata
        // `DiskFileAccess.save` falls back to the legacy V1 handler, which
        // writes no magic bytes at all, silently downgrading the file format.
        var preservedMetadata = EncryptedFileMetadata()
        if let sourceURL = media.underlyingMedia.first?.url,
           let original = try? await EncryptedMetadataHandler().readMetadata(from: sourceURL,
                                                                             keyBytes: album.key.keyBytes) {
            preservedMetadata = original
        }

        // Phase 1: Decrypt
        progressHandler?(.decrypting(progress: 0))
        reportProgress(taskId: task.id, overall: 0, startTime: startTime)

        let decryptedURLs = try await fileAccess.loadMediaToURLs(media: media) { [weak self] status in
            guard let self = self else { return }
            Task { @MainActor in
                switch status {
                case .downloading(let p), .decrypting(let p):
                    progressHandler?(.decrypting(progress: p))
                    self.reportProgress(taskId: task.id, overall: p * 0.33, startTime: startTime)
                default:
                    break
                }
            }
        }

        try Task.checkCancellation()
        progressHandler?(.decrypting(progress: 1.0))
        reportProgress(taskId: task.id, overall: 0.33, startTime: startTime)

        // Phase 2: Rotate each component
        var rotatedCleartextMedia: [CleartextMedia] = []
        let totalComponents = media.underlyingMedia.count

        for (index, component) in media.underlyingMedia.enumerated() {
            try Task.checkCancellation()

            guard index < decryptedURLs.count else { continue }
            let decryptedURL = decryptedURLs[index]

            let componentProgress: (Double) -> Void = { [weak self] p in
                guard let self = self else { return }
                let baseProgress = 0.33 + (Double(index) / Double(totalComponents)) * 0.34
                let componentRange = 0.34 / Double(totalComponents)
                let overall = baseProgress + p * componentRange
                progressHandler?(.rotating(progress: p))
                Task { @MainActor in
                    self.reportProgress(taskId: task.id, overall: overall, startTime: startTime)
                }
            }

            let rotatedURL: URL
            if component.mediaType == .video {
                rotatedURL = try await rotateVideo(at: decryptedURL, byDegrees: rotationAngle, progress: componentProgress)
            } else {
                rotatedURL = try await Task.detached(priority: .userInitiated) {
                    try Self.rotateImage(at: decryptedURL, byDegrees: rotationAngle)
                }.value
                componentProgress(1.0)
            }

            let cleartext = CleartextMedia(source: rotatedURL, mediaType: component.mediaType, id: component.id)
            rotatedCleartextMedia.append(cleartext)
        }

        try Task.checkCancellation()
        progressHandler?(.rotating(progress: 1.0))
        reportProgress(taskId: task.id, overall: 0.67, startTime: startTime)

        // Phase 3: Re-encrypt and save (with same media IDs)
        progressHandler?(.encrypting(progress: 0))

        let rotatedInteractable = try InteractableMedia(underlyingMedia: rotatedCleartextMedia)
        preservedMetadata.modificationDate = Date()
        _ = try await fileAccess.save(media: rotatedInteractable, metadata: preservedMetadata, progress: { [weak self] p in
            guard let self = self else { return }
            let overall = 0.67 + p * 0.28
            progressHandler?(.encrypting(progress: p))
            Task { @MainActor in
                self.reportProgress(taskId: task.id, overall: overall, startTime: startTime)
            }
        })

        try Task.checkCancellation()

        // Note: No need to delete original encrypted files — the save above
        // overwrites them in-place because the media IDs are preserved,
        // and driveURLForMedia derives the file path from the media ID.

        // Clean up temp files
        for url in decryptedURLs {
            try? FileManager.default.removeItem(at: url)
        }
        for cleartext in rotatedCleartextMedia {
            if let url = cleartext.url {
                try? FileManager.default.removeItem(at: url)
            }
        }

        progressHandler?(.completed)
        reportProgress(taskId: task.id, overall: 1.0, startTime: startTime)
    }

    // MARK: - Rotation

    private nonisolated static func rotateImage(at url: URL, byDegrees degrees: Int) throws -> URL {
        guard let image = UIImage(contentsOfFile: url.path) else {
            throw MediaEditError.couldNotLoadImage
        }

        let radians = CGFloat(degrees) * .pi / 180.0
        let rotatedImage = image.rotated(byRadians: radians)

        let originalExtension = url.pathExtension.lowercased()
        let data: Data
        let outputExtension: String

        switch originalExtension {
        case "png":
            guard let pngData = rotatedImage.pngData() else {
                throw MediaEditError.couldNotEncodeImage
            }
            data = pngData
            outputExtension = "png"
        case "heic":
            guard let heicData = Self.heicData(from: rotatedImage, compressionQuality: 0.95) else {
                throw MediaEditError.couldNotEncodeImage
            }
            data = heicData
            outputExtension = "heic"
        case "jpeg", "jpg":
            guard let jpegData = rotatedImage.jpegData(compressionQuality: 0.95) else {
                throw MediaEditError.couldNotEncodeImage
            }
            data = jpegData
            outputExtension = originalExtension
        default:
            guard let jpegData = rotatedImage.jpegData(compressionQuality: 0.95) else {
                throw MediaEditError.couldNotEncodeImage
            }
            data = jpegData
            outputExtension = "jpg"
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(outputExtension)

        try data.write(to: tempURL)
        return tempURL
    }

    private nonisolated static func heicData(from image: UIImage, compressionQuality: CGFloat) -> Data? {
        guard let cgImage = image.cgImage else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.heic.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: compressionQuality
        ]
        CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private func rotateVideo(at url: URL, byDegrees degrees: Int, progress: @escaping (Double) -> Void) async throws -> URL {
        let asset = AVURLAsset(url: url)
        let composition = AVMutableComposition()

        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw MediaEditError.couldNotLoadVideoTrack
        }

        let duration = try await asset.load(.duration)
        let timeRange = CMTimeRange(start: .zero, duration: duration)

        let compositionVideoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        try compositionVideoTrack?.insertTimeRange(timeRange, of: videoTrack, at: .zero)

        // Add audio track if present
        if let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first {
            let compositionAudioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            try? compositionAudioTrack?.insertTimeRange(timeRange, of: audioTrack, at: .zero)
        }

        // Apply rotation transform
        let radians = CGFloat(degrees) * .pi / 180.0
        let naturalSize = try await videoTrack.load(.naturalSize)
        let preferredTransform = try await videoTrack.load(.preferredTransform)
        let existingTransform = CGAffineTransform(
            a: preferredTransform.a,
            b: preferredTransform.b,
            c: preferredTransform.c,
            d: preferredTransform.d,
            tx: 0,
            ty: 0
        )

        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compositionVideoTrack!)
        let rotationTransform = existingTransform.concatenating(CGAffineTransform(rotationAngle: radians))

        // Calculate new size after rotation
        let transformedSize = naturalSize.applying(rotationTransform)
        let newSize = CGSize(width: abs(transformedSize.width), height: abs(transformedSize.height))

        let finalTransform = CGAffineTransform.identity
            .concatenating(CGAffineTransform(translationX: -naturalSize.width / 2, y: -naturalSize.height / 2))
            .concatenating(rotationTransform)
            .concatenating(CGAffineTransform(translationX: newSize.width / 2, y: newSize.height / 2))

        layerInstruction.setTransform(finalTransform, at: .zero)

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = timeRange
        instruction.layerInstructions = [layerInstruction]

        let videoComposition = AVMutableVideoComposition()
        videoComposition.instructions = [instruction]
        let nominalFrameRate = (try? await videoTrack.load(.nominalFrameRate)) ?? 0
        let frameRate = nominalFrameRate > 0 ? nominalFrameRate : 30
        let frameRateTimescale = CMTimeScale(max(1, Int32(frameRate.rounded())))
        videoComposition.frameDuration = CMTime(value: 1, timescale: frameRateTimescale)
        videoComposition.renderSize = newSize

        // Export
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")

        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw MediaEditError.couldNotCreateExportSession
        }

        session.outputURL = outputURL
        session.outputFileType = .mov
        session.videoComposition = videoComposition

        self.exportSession = session

        // Monitor progress
        let progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            progress(Double(session.progress))
        }

        await session.export()
        progressTimer.invalidate()
        self.exportSession = nil

        try Task.checkCancellation()

        switch session.status {
        case .completed:
            return outputURL
        case .cancelled:
            throw CancellationError()
        default:
            throw session.error ?? MediaEditError.exportFailed
        }
    }

    // MARK: - Progress Reporting

    private func reportProgress(taskId: String, overall: Double, startTime: Date) {
        let estimatedTimeRemaining = taskManager.calculateEstimatedTime(startTime: startTime, progress: overall)

        let progress = ImportProgressUpdate(
            taskId: taskId,
            currentFileIndex: 0,
            totalFiles: 1,
            currentFileProgress: overall,
            overallProgress: overall,
            currentFileName: nil,
            state: .running,
            estimatedTimeRemaining: estimatedTimeRemaining
        )

        taskManager.updateTaskProgress(taskId: taskId, progress: progress)
    }

    // MARK: - Background Task Management

    private func startBackgroundTask() {
        endBackgroundTask()

        activeBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "MediaEdit") {
            self.endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        if activeBackgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(activeBackgroundTask)
            activeBackgroundTask = .invalid
        }
    }
}

// MARK: - Edit Progress Phase

/// Phases of the edit operation, used to drive the OperationProgressView.
public enum EditProgressPhase {
    case decrypting(progress: Double)
    case rotating(progress: Double)
    case encrypting(progress: Double)
    case completed
}

// MARK: - Edit Errors

public enum MediaEditError: Error, LocalizedError {
    case couldNotLoadImage
    case couldNotEncodeImage
    case couldNotLoadVideoTrack
    case couldNotCreateExportSession
    case exportFailed

    public var errorDescription: String? {
        switch self {
        case .couldNotLoadImage: return "Could not load image for editing"
        case .couldNotEncodeImage: return "Could not encode rotated image"
        case .couldNotLoadVideoTrack: return "Could not load video track"
        case .couldNotCreateExportSession: return "Could not create video export session"
        case .exportFailed: return "Video export failed"
        }
    }
}

// MARK: - UIImage Rotation Extension

private extension UIImage {
    func rotated(byRadians radians: CGFloat) -> UIImage {
        let newSize: CGSize
        let transform: CGAffineTransform

        // For 90/270 degrees, swap width and height
        let normalizedRadians = radians.truncatingRemainder(dividingBy: 2 * .pi)
        let isOddMultipleOf90 = abs(abs(normalizedRadians) - .pi / 2) < 0.01 || abs(abs(normalizedRadians) - 3 * .pi / 2) < 0.01

        if isOddMultipleOf90 {
            newSize = CGSize(width: size.height, height: size.width)
        } else {
            newSize = size
        }

        let format = UIGraphicsImageRendererFormat()
        format.scale = self.scale
        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
        return renderer.image { context in
            let cgContext = context.cgContext
            cgContext.translateBy(x: newSize.width / 2, y: newSize.height / 2)
            cgContext.rotate(by: radians)
            draw(in: CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height))
        }
    }
}
