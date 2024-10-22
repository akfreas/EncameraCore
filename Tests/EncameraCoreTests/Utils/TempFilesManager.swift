//
//  TempFilesManager.swift
//  Encamera
//
//  Created by Alexander Freas on 22.11.21.
//

import Foundation
import UIKit
import Combine
@testable import EncameraCore

public class TempFilesManager {
    static var shared: TempFilesManager = TempFilesManager()

    private var createdTempFiles = Set<URL>()
    private var cancellables = Set<AnyCancellable>()
    private var tempUrl = URL(fileURLWithPath: NSTemporaryDirectory(),
                              isDirectory: true)
    
    init(subdirectory: String) {
        self.tempUrl = URL(fileURLWithPath: NSTemporaryDirectory(),
                           isDirectory: true).appendingPathComponent(subdirectory)
        try! FileManager.default.createDirectory(at: tempUrl, withIntermediateDirectories: true)
    }
    
    init() {}
    
    func createTempURL(for mediaType: MediaType, id: String) -> URL {
        let path = tempUrl.appendingPathComponent(id).appendingPathExtension(mediaType.encryptedFileExtension)
        createdTempFiles.insert(path)
        return path
    }

    
}
