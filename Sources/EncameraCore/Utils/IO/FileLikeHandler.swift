//
//  FileLikeHandler.swift
//  Encamera
//
//  Created by Alexander Freas on 20.06.22.
//

import Foundation

class FileLikeHandler<T: MediaDescribing>: FileLikeBlockReader {
    
    
    private var reader: FileLikeBlockReader
    
    var size: UInt64 {
        reader.size
    }
    
    init(media: T, mode: BlockIOMode) throws {
        switch media.source {
        case let source where source is Data:
            self.reader = DataBlockReader(source: source as! Data)
        case let source where media.source is URL:
            self.reader = try DiskBlockReader(source: source as! URL, mode: mode)
        default:
            fatalError()
        }
    }
    
    
    func read(upToCount: Int) throws -> Data? {
        try reader.read(upToCount: upToCount)
    }
    func closeReader() throws {
        try reader.closeReader()
    }
    func prepareIfDoesNotExist() throws {
        try reader.prepareIfDoesNotExist()
    }
    
    func write(contentsOf data: Data) throws {
        try reader.write(contentsOf: data)
    }
}
