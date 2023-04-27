//
//  DataBlockReader.swift
//  Encamera
//
//  Created by Alexander Freas on 20.06.22.
//

import Foundation

class DataBlockReader: FileLikeBlockReader {
    
    
    private var source: Data
    
    var size: UInt64 {
        return UInt64(source.count)
    }
    
    init(source: Data) {
        self.source = source
    }
    
    func read(upToCount count: Int) throws -> Data? {
        let next = count > source.count ? source.count : count
        if next == 0 {
            return nil
        }
        let reduced = source.advanced(by: next)
        let block = source.subdata(in: 0..<next)
        source = reduced
        return block
    }
    
    func closeReader() {
        
    }
    
    func prepareIfDoesNotExist() throws {
        source = Data()
    }
    
    func write(contentsOf data: Data) throws {
        source.append(contentsOf: data)
    }
}
