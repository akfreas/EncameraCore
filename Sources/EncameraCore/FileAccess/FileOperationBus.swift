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
    case delete(EncryptedMedia)
}


public struct FileOperationBus {
    
    public static var shared: FileOperationBus = FileOperationBus()
    
    public var operations: AnyPublisher<FileOperation, Never> {
        operationSubject.share().eraseToAnyPublisher()
    }
    
    private var operationSubject: PassthroughSubject<FileOperation, Never> = PassthroughSubject()

    func didCreate(_ media: EncryptedMedia) {
        operationSubject.send(.create(media))
    }
    
    func didDelete(_ media: EncryptedMedia) {
        operationSubject.send(.delete(media))
    }
}
