//
//  SharedFileAccess.swift
//  EncameraCore
//
//  Created by Alexander Freas on 23.01.23.
//

import Foundation

public class SharedFileAccess {
    
    
    private static var importUrl: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.me.freas.encamera")?
            .appendingPathComponent("ImportImages")
    }
    
    public static func copyContentsOfURLToShared(url: URL) {
        guard let containerUrl = importUrl else {
            fatalError("Could not get shared container url")
        }
        
        let fileName = url.lastPathComponent
        let destinationURL = containerUrl.appendingPathComponent(fileName)
        
        do {
            try FileManager.default.copyItem(at: url, to: destinationURL)
        } catch {
            print("Error while copying file from \(url) to \(destinationURL): \(error.localizedDescription)")
        }
    }

    
    public static func saveCleartextDataToShared(data: Data) {
        guard let containerUrl = importUrl else {
            fatalError("Could not get shared container url")
        }
        
        
        try! data.write(to: containerUrl)
    }
    
    public static func getSharedCleartextData() -> Data? {
        guard let containerUrl = importUrl else {
            fatalError("Could not get shared container url")
        }
        return try? Data(contentsOf: containerUrl)
    }
    
    public static func deleteSharedData() {
        guard let containerUrl = importUrl else {
            fatalError("Could not get shared container url")
        }
        try? FileManager.default.removeItem(at: containerUrl)
    }
}
