//
//  ImportError.swift
//  EncameraCore
//
//  Created by Alexander Freas on 24.07.25.
//
import Foundation
import BackgroundTasks
import Combine
import UIKit




// MARK: - Supporting Types

public enum BackgroundImportError: Error {
    case configurationError
    case taskNotFound
    case operationCancelled
    case mismatchedType
    /// Every item in a batch import failed, so the task is finalized as failed
    /// rather than completed-with-failures.
    case allImportsFailed(failureCount: Int)
}
