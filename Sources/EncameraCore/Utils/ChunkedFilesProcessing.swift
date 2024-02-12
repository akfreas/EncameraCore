//
//  Chunked.swift
//  Encamera
//
//  Created by Alexander Freas on 19.05.22.
//

import Foundation
import Combine

class ChunkedFilesProcessingSubscription<S: Subscriber, T: MediaDescribing>: Subscription where S.Input == ([UInt8], Double, Bool), S.Failure == Error {


    enum ChunkedFilesError: Error {
        case sourceFileAccessError
    }

    private let sourceFileHandle: FileLikeHandler<T>
    private let blockSize: Int
    private var subscriber: S?


    init(sourceFileHandle: FileLikeHandler<T>, blockSize: Int, subscriber: S) {
        self.subscriber = subscriber
        self.blockSize = blockSize
        self.sourceFileHandle = sourceFileHandle
    }

    func request(_ demand: Subscribers.Demand) {
        guard demand > 0 else {
            return
        }

        do {
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: blockSize)
            defer {
                buffer.deallocate()
            }

            var byteCount: UInt64 = 0
            while true {
                guard let data = try sourceFileHandle.read(upToCount: blockSize) else {
                    subscriber?.receive(completion: .failure(ChunkedFilesError.sourceFileAccessError))
                    return
                }

                let final = data.count < blockSize
                byteCount += UInt64(data.count)
                let progress = Double(byteCount) / Double(sourceFileHandle.size)

                data.copyBytes(to: buffer, count: data.count)
                let byteArray = Array(UnsafeBufferPointer(start: buffer, count: data.count))

                let _ = subscriber?.receive((byteArray, progress, final))

                if final { break }
            }
            try sourceFileHandle.closeReader()
            subscriber?.receive(completion: .finished)
        } catch {
            subscriber?.receive(completion: .failure(error))
        }
    }
    func cancel() {
        try? sourceFileHandle.closeReader()
    }
}

struct ChunkedFileProcessingPublisher<T: MediaDescribing>: Publisher {
    typealias Output = ([UInt8], Double, Bool)
    typealias Failure = Error

    let sourceFileHandle: FileLikeHandler<T>
    let blockSize: Int

    init(sourceFileHandle: FileLikeHandler<T>,
         blockSize: Int) {
        self.sourceFileHandle = sourceFileHandle
        self.blockSize = blockSize
    }

    func receive<S>(subscriber: S) where S : Subscriber, Failure == S.Failure, ([UInt8], Double, Bool) == S.Input {
        let subscription = ChunkedFilesProcessingSubscription(sourceFileHandle: sourceFileHandle, blockSize: blockSize, subscriber: subscriber)
        subscriber.receive(subscription: subscription)
    }
}
