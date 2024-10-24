//
//  ShareMediaUtil.swift
//  EncameraCore
//
//  Created by Alexander Freas on 23.10.24.
//

import Foundation
import UIKit
import LinkPresentation
import UniformTypeIdentifiers

public enum SharingError: Error {
    case noMediaToShare
    case errorDownloading
    case errorSharing(internalError: Error)
}

public class ShareMediaUtil: NSObject, UIActivityItemSource, DebugPrintable {

    let targetMedia: [InteractableMedia<EncryptedMedia>]
    let fileAccess: FileAccess
    var currentSharingPreview: PreviewModel?
    var preparedMediaURLs: [URL] = []

    public init(fileAccess: FileAccess, targetMedia: [InteractableMedia<EncryptedMedia>]) {
        self.targetMedia = targetMedia
        self.fileAccess = fileAccess
        super.init()
    }

    public func prepareSharingData(progress: @escaping (FileLoadingStatus) -> Void) async throws {

        guard let firstMedia = targetMedia.first else {
            return
        }
        currentSharingPreview = try await fileAccess.loadMediaPreview(for: firstMedia)

        let totalMediaToLoad = targetMedia
            .map({$0.underlyingMedia.count})
            .reduce(0, +)

        guard totalMediaToLoad > 0 else {
            progress(.loaded)
            return
        }

        var overallProgress: Double = 0.0
        let progressLock = NSLock() // A lock to ensure thread-safety when updating overallProgress

        for media in targetMedia {
            do {
                let media = try await self.fileAccess.loadMediaToURLs(media: media) { status in
                    // Using lock to ensure thread-safety when updating overall progress
                    self.printDebug("Status: \(status), overallstatus: \(overallProgress), totalMedia: \(totalMediaToLoad)")
                    progressLock.lock()
                    defer { progressLock.unlock() }

                    switch status {
                    case .downloading(let percent):
                        // Update the overall progress based on the percent of the current media
                        overallProgress += (percent / Double(totalMediaToLoad))
                    case .decrypting(let percent):
                        // Update the overall progress based on the percent of the current media being decrypted
                        overallProgress += (percent / Double(totalMediaToLoad))
                    case .loaded:
                        // No action required, as the item is fully loaded
                        break
                    case .notLoaded:
                        // No progress to report if the item is not loaded
                        break
                    }

                    // Make sure the progress value is within bounds (0.0 to 1.0)
                    overallProgress = min(max(overallProgress, 0.0), 1.0)

                    // Report the overall progress
                    progress(.downloading(progress: overallProgress))
                }
                self.preparedMediaURLs.append(contentsOf: media)
            } catch {
                print("Error loading media: \(error)")
            }
        }

        // Once all media items are loaded, report the final status as loaded
        progress(.loaded)
    }

    @MainActor
    public func showShareSheet() async throws {
        guard !preparedMediaURLs.isEmpty else {
            printDebug("No media loaded")
            return
        }

        let activityView = UIActivityViewController(activityItems: self.preparedMediaURLs + [self], applicationActivities: nil)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            activityView.completionWithItemsHandler = { activityType, completed, returnedItems, error in
                if let error = error {
                    self.printDebug("Share error: \(error.localizedDescription)")
                    continuation.resume(throwing: SharingError.errorSharing(internalError: error))
                } else {
                    continuation.resume()
                }
            }

            let allScenes = UIApplication.shared.connectedScenes
            let scene = allScenes.first { $0.activationState == .foregroundActive }

            if let windowScene = scene as? UIWindowScene {
                windowScene.keyWindow?.rootViewController?.present(activityView, animated: true, completion: nil)
            }
        }
    }


    public func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        return "Encamera Media"
    }

    public func activityViewController(_ activityViewController: UIActivityViewController, itemForActivityType activityType: UIActivity.ActivityType?) -> Any? {
        return preparedMediaURLs
    }


    public func activityViewControllerLinkMetadata(_ activityViewController: UIActivityViewController) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()

        if let firstMedia = targetMedia.first, let thumbnailData = currentSharingPreview?.thumbnailMedia.data {
            let imageProvider = NSItemProvider(item: thumbnailData as NSData, typeIdentifier: UTType.png.identifier)
            metadata.imageProvider = imageProvider
            metadata.title = targetMedia.count > 1 ? "Multiple Media Items" : "Media Item"
        } else {
            return nil
        }

        return metadata
    }





}

