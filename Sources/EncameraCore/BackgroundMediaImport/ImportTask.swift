//
//  ImportTask.swift
//  EncameraCore
//
//  Created by Alexander Freas on 24.07.25.
//
import Foundation
import BackgroundTasks
import Combine
import UIKit

public enum ImportSource: String, Codable, CaseIterable {
    case photos = "photos"              // Media from photo library (can delete temp files)
    case files = "files"                // Media from file system (should not delete originals)
    case shareExtension = "shareExtension"  // Media from Share Extension (files in app group container)
    
    /// Whether temporary files can be safely deleted after import for this source type
    public var canDeleteTempFilesAfterImport: Bool {
        switch self {
        case .photos:
            return true  // Photo library imports copy to temp directory, safe to delete
        case .files:
            return false // File imports reference user's files, should not delete
        case .shareExtension:
            return true  // Share Extension files are in app group, safe to delete after import
        }
    }
}

/// Identifies the type of background file task
public enum FileTaskType: String, CaseIterable {
    case importMedia
    case moveMedia
    case exportMedia
    case editMedia
    case migrateStorage
}

public protocol BackgroundFileTask: Equatable  {
    var id: String { get }
    var taskType: FileTaskType { get }
    var createdAt: Date { get }
    /// Settable so `BackgroundTaskManager` can write through the existential.
    /// If this ever goes back to `get`-only, the manager has to hand-roll a cast
    /// per conformer again and new task types silently stop receiving updates.
    var progress: ImportProgressUpdate { get set }
    var state: FileTaskState { get }
    var assetIdentifiers: [String] { get }
    /// Whether the user can cancel this task from the progress card. Tasks
    /// that have no cancellation handler (e.g. the startup index migration)
    /// should return `false` so the UI doesn't expose a Cancel button that
    /// stops the spinner without actually halting the work.
    var isCancelable: Bool { get }
}

extension BackgroundFileTask {
    public var isCancelable: Bool { true }
}

public struct ImportTask: BackgroundFileTask {
    public let id: String
    public let taskType: FileTaskType = .importMedia
    public let media: [CleartextMedia]
    public let albumId: String
    public let source: ImportSource
    public let createdAt: Date
    public var progress: ImportProgressUpdate
    public var state: FileTaskState {
        progress.state
    }
    public private(set) var assetIdentifiers: [String]
    /// Identifier for the user-initiated batch. Multiple ImportTasks with the same userBatchId
    /// were created from the same user selection (e.g., when selecting 20 photos from the photo picker,
    /// they may be split into multiple technical batches for processing efficiency).
    public let userBatchId: String?
    
    /// The number of unique media items (InteractableMedia) in this task.
    /// This groups live photo components (image + video with same ID) as a single item.
    public var uniqueMediaCount: Int {
        Set(media.map { $0.id }).count
    }
    
    public init(id: String = UUID().uuidString, media: [CleartextMedia], albumId: String, source: ImportSource, assetIdentifiers: [String] = [], userBatchId: String? = nil) {
        self.id = id
        self.media = media
        self.albumId = albumId
        self.source = source
        self.createdAt = Date()
        self.assetIdentifiers = assetIdentifiers
        self.userBatchId = userBatchId
        // Calculate totalFiles from unique media IDs so live photos count as one item
        let uniqueMediaCount = Set(media.map { $0.id }).count
        self.progress = ImportProgressUpdate(
            taskId: id,
            currentFileIndex: 0,
            totalFiles: uniqueMediaCount,
            currentFileProgress: 0.0,
            overallProgress: 0.0,
            currentFileName: nil,
            state: .idle,
            estimatedTimeRemaining: nil
        )
    }
    
    /// Creates an import task with a known total file count but no media yet.
    /// Used for streaming imports where items are loaded and imported one at a time.
    public init(id: String = UUID().uuidString, totalFiles: Int, albumId: String, source: ImportSource, userBatchId: String? = nil) {
        self.id = id
        self.media = []
        self.albumId = albumId
        self.source = source
        self.createdAt = Date()
        self.assetIdentifiers = []
        self.userBatchId = userBatchId
        self.progress = ImportProgressUpdate(
            taskId: id,
            currentFileIndex: 0,
            totalFiles: totalFiles,
            currentFileProgress: 0.0,
            overallProgress: 0.0,
            currentFileName: nil,
            state: .idle,
            estimatedTimeRemaining: nil
        )
    }

    public static func ==(lhs: ImportTask, rhs: ImportTask) -> Bool {
        return lhs.id == rhs.id
    }
    
    /// Creates a copy of this task with updated asset identifiers.
    /// Used for streaming imports where asset IDs are collected during processing.
    public func withAssetIdentifiers(_ newAssetIdentifiers: [String]) -> ImportTask {
        var copy = self
        copy.assetIdentifiers = newAssetIdentifiers
        return copy
    }
}
