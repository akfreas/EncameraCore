//
//  BlockHandling.swift
//  Encamera
//
//  Created by Alexander Freas on 13.06.22.
//

import Foundation

protocol FileLikeBlockReader  {
    
    var size: UInt64 { get }
    
    func prepareIfDoesNotExist() throws
    func closeReader() throws
    func read(upToCount: Int) throws -> Data?
    func write(contentsOf data: Data) throws

}

enum BlockIOMode {
    case reading
    case writing
}
