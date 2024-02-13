//
//  FileUtils.swift
//  EncameraTests
//
//  Created by Alexander Freas on 22.06.22.
//

import Foundation
@testable import EncameraCore

public class FileUtils {
    
    static var tempFilesManager = TempFilesManager(subdirectory: "test_suite")
    
    private static func createUrl(for file: String) -> URL {
        return URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("TestData/\(file)")
        
    }
        
    static func createNewMovieFile() throws -> CleartextMedia<URL> {        
        let tempURL = tempFilesManager.createTempURL(for: .video, id: NSUUID().uuidString)
         try! FileManager.default.copyItem(at: createUrl(for: "test.mov"), to: tempURL)
        let sourceMedia = CleartextMedia(source: tempURL)
        
        return sourceMedia
    }

    static func createNewTextFile(content: String) throws -> CleartextMedia<Data> {
        // Create a temporary URL for the text file
        let tempURL = tempFilesManager.createTempURL(for: .preview, id: NSUUID().uuidString)

        // Convert the content string to Data
        guard let contentData = content.data(using: .utf8) else {
            throw NSError(domain: "FileUtils", code: 0, userInfo: [NSLocalizedDescriptionKey: "Unable to convert string to Data"])
        }

        // Write the content Data to the temporary file
        try contentData.write(to: tempURL, options: .atomic)

        // Return the CleartextMedia object with the content Data
        let sourceMedia = CleartextMedia(source: contentData, mediaType: .preview, id: NSUUID().uuidString)

        return sourceMedia
    }


    static func createNewImageMedia() throws -> CleartextMedia<URL> {
        let sourceUrl = createUrl(for: "dog.jpg")
        
        
        let tempURL = tempFilesManager.createTempURL(for: .photo, id: NSUUID().uuidString)
        try! FileManager.default.copyItem(at: sourceUrl, to: tempURL)
        let sourceMedia = CleartextMedia(source: tempURL)
        
        return sourceMedia
        
    }
    
    static func createNewDataImageMedia(id: String? = nil) throws -> CleartextMedia<Data> {
        let sourceUrl = createUrl(for: "image.jpg")
        let sourceData = try Data(contentsOf: sourceUrl)
        if let id = id {
            let sourceMedia = CleartextMedia(source: sourceData, mediaType: .photo, id: id)
            return sourceMedia
        }
        let sourceMedia = CleartextMedia(source: sourceData)
        return sourceMedia
    }
    
}
