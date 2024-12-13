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

    func processFile(progressUpdate: @escaping (Double) -> Void) -> AsyncThrowingStream<[UInt8], Error> {
        AsyncThrowingStream { continuation in
            Task {
                var byteCount: UInt64 = 0

                do {
                    while !Task.isCancelled {
                        autoreleasepool {
                            guard let data = try? sourceFileHandle.read(upToCount: blockSize) else {
                                continuation.finish()
                                return
                            }


                            let isFinalChunk = data.count < blockSize
                            byteCount += UInt64(data.count)
                            let progress = Double(byteCount) / Double(sourceFileHandle.size)

                            progressUpdate(progress)
                            continuation.yield(Array(data))
                            if isFinalChunk {
                                return
                            }

                        }

                    }

                    if Task.isCancelled {
                        try sourceFileHandle.closeReader()
                        continuation.finish(throwing: ChunkedFilesError.operationCancelled)
                        return
                    }

                    try sourceFileHandle.closeReader()
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
