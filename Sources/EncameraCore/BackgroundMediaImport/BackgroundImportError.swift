//
//  ImportError.swift
//  EncameraCore
//
//  Created by Alexander Freas on 24.07.25.
//
import Foundation
import BackgroundTasks
import Combine
import Photos
import UIKit




// MARK: - Supporting Types

public enum BackgroundImportError: Error, Equatable {
    case configurationError
    case taskNotFound
    case operationCancelled
    case mismatchedType
    /// The photo library will not give us this asset's data. Under limited access this
    /// is what un-sharing a photo between selection and import looks like, and it is a
    /// different problem from a corrupt or unsupported file.
    case assetUnavailable
    /// The asset lives in iCloud and could not be downloaded. Network access is already
    /// enabled on every request, so this is a genuinely distinct condition from
    /// `assetUnavailable` and deserves its own reason.
    case assetDownloadFailed
    /// Every item in a batch import failed, so the task is finalized as failed
    /// rather than completed-with-failures.
    case allImportsFailed(failureCount: Int)

    /// Classifies a PhotoKit `info` dictionary into an import error.
    ///
    /// PhotoKit reports failure through `info` rather than by throwing: `PHImageErrorKey`
    /// carries the underlying error and `PHImageCancelledKey` marks a cancelled request.
    /// Discarding that dictionary — which every load path used to do — is what made
    /// "you un-shared this photo" indistinguishable from "this file is corrupt".
    public static func fromPhotoKitInfo(_ info: [AnyHashable: Any]?) -> BackgroundImportError {
        guard let info else { return .assetUnavailable }

        if let cancelled = info[PHImageCancelledKey] as? Bool, cancelled {
            return .operationCancelled
        }
        guard let error = info[PHImageErrorKey] as? NSError else {
            return .assetUnavailable
        }
        return isNetworkFailure(error) ? .assetDownloadFailed : .assetUnavailable
    }

    private static func isNetworkFailure(_ error: NSError) -> Bool {
        if error.domain == NSURLErrorDomain { return true }
        guard error.domain == PHPhotosErrorDomain else { return false }
        return error.code == PHPhotosError.networkAccessRequired.rawValue
            || error.code == PHPhotosError.networkError.rawValue
    }
}
