//
//  FileOperationBus.swift
//  Encamera
//
//  Created by Alexander Freas on 17.09.22.
//

import Foundation
import Combine


public enum FileOperation {
    case create(EncryptedMedia)
    case delete([EncryptedMedia])
    case move(from: [EncryptedMedia], to: Album)
    case albumCoverChanged
}

/// Reference-typed backing for `FileOperationBus.isSuppressed` so the flag is
/// shared across the value-type copies the bus is accessed through.
private final class FileOperationSuppressionBox {
    var isSuppressed = false
}


public struct FileOperationBus {

    public static var shared: FileOperationBus = FileOperationBus()

    public var operations: AnyPublisher<FileOperation, Never> {
        operationSubject.share().eraseToAnyPublisher()
    }

    private var operationSubject: PassthroughSubject<FileOperation, Never> = PassthroughSubject()
    private let suppressionBox = FileOperationSuppressionBox()

    /// When `true`, `didCreate`/`didDelete`/`didMove` drop their events instead
    /// of publishing them. Each event triggers a full album-grid and gallery
    /// refresh, so a bulk operation that emits one event per item is O(n²).
    /// Suppress for the duration of the batch, then emit a single coalesced
    /// event so subscribers refresh exactly once.
    public var isSuppressed: Bool {
        get { suppressionBox.isSuppressed }
        nonmutating set { suppressionBox.isSuppressed = newValue }
    }

    public func didCreate(_ media: EncryptedMedia) {
        guard !suppressionBox.isSuppressed else { return }
        operationSubject.send(.create(media))
    }

    public func didDelete(_ media: [EncryptedMedia]) {
        guard !suppressionBox.isSuppressed else { return }
        operationSubject.send(.delete(media))
    }

    public func didMove(_ media: [EncryptedMedia], to album: Album) {
        guard !suppressionBox.isSuppressed else { return }
        operationSubject.send(.move(from: media, to: album))
    }

    public func albumCoverChanged() {
        operationSubject.send(.albumCoverChanged)
    }
}
