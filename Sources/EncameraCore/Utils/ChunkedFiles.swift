//
//  File.swift
//  EncameraCore
//
//  Created by Alexander Freas on 10.12.24.
//

import Foundation

public enum ChunkedFilesError: Error {
    case sourceFileAccessError
    case operationCancelled
}

class ChunkedFilesProcessor<T: MediaDescribing> {
    private let sourceFileHandle: FileLikeHandler<T>
    private let blockSize: Int

    init(sourceFileHandle: FileLikeHandler<T>, blockSize: Int) {
        self.sourceFileHandle = sourceFileHandle
        self.blockSize = blockSize
    }

    func processFile(progressUpdate: @escaping (Double) -> Void) throws -> [[UInt8]] {
        var result = [[UInt8]]()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: blockSize)
        defer {
            buffer.deallocate()
        }

        var byteCount: UInt64 = 0
        while !Task.isCancelled {
            guard let data = try sourceFileHandle.read(upToCount: blockSize) else {
                throw CancellationError()
            }

            let isFinalChunk = data.count < blockSize
            byteCount += UInt64(data.count)
            let progress = Double(byteCount) / Double(sourceFileHandle.size)

            // Provide progress update
            progressUpdate(progress)

            // Copy data to buffer
            data.copyBytes(to: buffer, count: data.count)
            let byteArray = Array(UnsafeBufferPointer(start: buffer, count: data.count))
            result.append(byteArray)

            if isFinalChunk {
                break
            }
        }

        if Task.isCancelled {
            try sourceFileHandle.closeReader()
            throw ChunkedFilesError.operationCancelled
        }

        try sourceFileHandle.closeReader()
        return result
    }
}
