//
//  PendingImportManager.swift
//  EncameraCore
//
//  Created for Share Extension import coordination
//

import Foundation
import Combine
import UIKit

/// Outcome of the most recent pending import, published so the app can expose it
/// as an accessibility marker. The import runs detached and its failures are only
/// logged, so without this a dropped import is indistinguishable from a slow one.
@MainActor
public final class PendingImportOutcome: ObservableObject {
    public static let shared = PendingImportOutcome()
    private init() {}

    /// "none" until an import finishes; then "ok=<n>:fail=<n>:album=<id>" or
    /// "error=<description>:album=<id>".
    @Published public private(set) var summary: String = "none"

    public func record(_ summary: String) {
        self.summary = summary
    }
}

/// The pending-import operations a destination picker drives, so a view model can
/// be exercised without the App Group container or a real background import.
@MainActor
public protocol PendingImportPerforming {
    var pendingMedia: [CleartextMedia] { get }
    func loadPendingMedia() async
    func importPendingMedia(toAlbumId albumId: String, albumManager: AlbumManaging) async throws -> Int
    func cancelPendingImports() async throws
}

/// Manages pending media imports from the Share Extension to the main app.
/// This class coordinates the detection and processing of media files that were
/// shared to Encamera from other apps via the Share Extension.
@MainActor
public class PendingImportManager: ObservableObject, DebugPrintable {
    
    // MARK: - Shared Instance
    
    public static let shared = PendingImportManager()
    
    // MARK: - Published Properties
    
    /// Whether there are pending imports waiting to be processed
    @Published public private(set) var hasPendingImports: Bool = false
    
    /// The count of pending media files
    @Published public private(set) var pendingCount: Int = 0
    
    /// The pending media items (loaded on demand)
    @Published public private(set) var pendingMedia: [CleartextMedia] = []
    
    /// Whether we're currently checking for pending imports
    @Published public private(set) var isChecking: Bool = false
    
    // MARK: - Private Properties
    
    private let appGroupFileAccess = AppGroupFileAccess.shared
    private var cancellables = Set<AnyCancellable>()
    
    /// UserDefaults key for tracking when imports were last added (used by extension)
    private static let lastImportTimestampKey = "PendingImport_LastTimestamp"
    
    /// UserDefaults key for tracking pending count (set by extension for quick access)
    private static let pendingCountKey = "PendingImport_Count"
    
    /// Shared UserDefaults suite for App Group
    private var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: UserDefaultUtils.appGroup)
    }
    
    // MARK: - Initialization
    
    public init() {
        setupNotificationObservers()
    }
    
    // MARK: - Public API
    
    /// Checks for pending imports from the Share Extension
    /// Call this when the app becomes active or when triggered by a deep link
    public func checkForPendingImports() async {
        guard !isChecking else {
            printDebug("Already checking for pending imports, skipping")
            return
        }
        
        isChecking = true
        defer { isChecking = false }
        
        printDebug("Checking for pending imports from Share Extension...")
        
        // Move file I/O off the main thread to avoid blocking during foreground transition
        // This is important because this check happens when the app becomes active,
        // which is the same time biometric authentication is trying to run
        let fileAccess = appGroupFileAccess
        let count = await Task.detached(priority: .utility) {
            fileAccess.pendingMediaCount()
        }.value
        
        let hadPending = hasPendingImports
        
        pendingCount = count
        hasPendingImports = count > 0
        
        if hasPendingImports {
            printDebug("Found \(count) pending media files")
        } else if hadPending {
            printDebug("No more pending imports")
        }
    }
    
    /// Loads all pending media items (call when showing the import UI)
    public func loadPendingMedia() async {
        printDebug("Loading pending media items...")
        let media = await appGroupFileAccess.enumerateMedia()
        pendingMedia = media
        pendingCount = media.count
        hasPendingImports = !media.isEmpty
        printDebug("Loaded \(media.count) pending media items")
    }
    
    /// Imports all pending media to the specified album.
    /// This method returns immediately after starting the import - it does NOT wait for completion.
    /// The import continues in the background, and cleanup happens when the import completes.
    /// - Parameters:
    ///   - albumId: The album ID to import media into
    ///   - albumManager: The album manager for configuration
    /// - Returns: The number of media items that will be imported
    public func importPendingMedia(
        toAlbumId albumId: String,
        albumManager: AlbumManaging
    ) async throws -> Int {
        printDebug("Starting import of pending media to album: \(albumId)")

        // The handler is otherwise only configured when an album is opened, so a
        // share-sheet import on a launch that restored no current album would fail
        // validation and drop the media with nothing shown to the user.
        MediaImportHandler.shared.configure(albumManager: albumManager)

        // Ensure we have the latest pending media
        await loadPendingMedia()
        
        guard !pendingMedia.isEmpty else {
            printDebug("No pending media to import")
            return 0
        }
        
        let mediaToImport = pendingMedia
        let count = mediaToImport.count
        
        // Clear pending state IMMEDIATELY so the modal doesn't reappear
        // The actual files will be cleaned up after import completes
        pendingMedia = []
        pendingCount = 0
        hasPendingImports = false
        clearPendingMetadata()
        
        // Fire-and-forget: Start the import in a detached task so we return immediately
        // The import will continue in the background
        Task.detached { [weak self] in
            do {
                // Use the MediaImportHandler for the actual import
                let result = try await MediaImportHandler.shared.startImport(
                    media: mediaToImport,
                    albumId: albumId,
                    source: .shareExtension,
                    assetIdentifiers: []
                )
                await PendingImportOutcome.shared.record(
                    "ok=\(result.success):fail=\(result.failure):album=\(albumId)"
                )

                // Clean up the app group container after import completes
                await self?.cleanupAfterImport(importedMedia: mediaToImport)
            } catch {
                await PendingImportOutcome.shared.record("error=\(error):album=\(albumId)")
                await self?.printDebug("Import failed: \(error)")
            }
        }
        
        // Return immediately with the count - don't wait for import to complete
        return count
    }
    
    /// Cancels/dismisses pending imports without importing them
    public func cancelPendingImports() async throws {
        printDebug("Cancelling pending imports - deleting files from app group")
        
        try await appGroupFileAccess.deleteAllMedia()
        
        pendingMedia = []
        pendingCount = 0
        hasPendingImports = false
        
        // Clear the metadata in shared UserDefaults
        clearPendingMetadata()
        
        printDebug("Pending imports cancelled and cleaned up")
    }
    
    /// Deletes specific pending media items
    public func deletePendingMedia(_ media: [CleartextMedia]) async throws {
        try await appGroupFileAccess.delete(mediaList: media)
        
        // Reload to update counts
        await loadPendingMedia()
    }
    
    // MARK: - Metadata Management (Used by Share Extension)
    
    /// Records that new media was added to the pending queue
    /// Call this from the Share Extension after saving files
    public func recordPendingImport(count: Int) {
        sharedDefaults?.set(Date().timeIntervalSince1970, forKey: Self.lastImportTimestampKey)
        
        let currentCount = sharedDefaults?.integer(forKey: Self.pendingCountKey) ?? 0
        sharedDefaults?.set(currentCount + count, forKey: Self.pendingCountKey)
        sharedDefaults?.synchronize()
        
        printDebug("Recorded \(count) new pending imports (total: \(currentCount + count))")
    }
    
    /// Gets the timestamp of the last pending import
    public func lastPendingImportTimestamp() -> Date? {
        guard let timestamp = sharedDefaults?.double(forKey: Self.lastImportTimestampKey),
              timestamp > 0 else {
            return nil
        }
        return Date(timeIntervalSince1970: timestamp)
    }
    
    /// Clears the pending import metadata
    private func clearPendingMetadata() {
        sharedDefaults?.removeObject(forKey: Self.lastImportTimestampKey)
        sharedDefaults?.removeObject(forKey: Self.pendingCountKey)
        sharedDefaults?.synchronize()
    }
    
    // MARK: - Private Methods
    
    private func cleanupAfterImport(importedMedia: [CleartextMedia]) async {
        printDebug("Cleaning up \(importedMedia.count) imported files from app group")
        
        do {
            try await appGroupFileAccess.delete(mediaList: importedMedia)
            printDebug("Successfully cleaned up imported files")
        } catch {
            printDebug("WARNING: Failed to clean up some imported files: \(error)")
        }
        
        // Reset state
        pendingMedia = []
        pendingCount = 0
        hasPendingImports = false
        clearPendingMetadata()
    }
    
    private func setupNotificationObservers() {
        // Check for pending imports when app becomes active
        // Use a delay to avoid competing with biometric authentication during foreground transition
        NotificationUtils.didBecomeActivePublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in
                    // Delay non-critical file I/O to let biometrics complete first
                    try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
                    await self?.checkForPendingImports()
                }
            }
            .store(in: &cancellables)
        
        // Remove the willEnterForeground observer - didBecomeActive is sufficient
        // and having both causes redundant work during foreground transition
    }
}

extension PendingImportManager: PendingImportPerforming {}
