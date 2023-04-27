//
//  SharedFileAccess.swift
//  EncameraCore
//
//  Created by Alexander Freas on 23.01.23.
//

import Foundation

public class SharedFileAccess {
    
    public static func saveCleartextDataToShared(data: Data) {
        guard let containerUrl = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.me.freas.encamera")?.appendingPathComponent("SharedImage") else {
            fatalError("Could not get shared container url")
        }
        
        try! data.write(to: containerUrl)
    }
    
    public static func getSharedCleartextData() -> Data? {
        guard let containerUrl = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.me.freas.encamera")?.appendingPathComponent("SharedImage") else {
            fatalError("Could not get shared container url")
        }
        return try? Data(contentsOf: containerUrl)
    }
    
    public static func deleteSharedData() {
        guard let containerUrl = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.me.freas.encamera")?.appendingPathComponent("SharedImage") else {
            fatalError("Could not get shared container url")
        }
        try? FileManager.default.removeItem(at: containerUrl)
    }
}
