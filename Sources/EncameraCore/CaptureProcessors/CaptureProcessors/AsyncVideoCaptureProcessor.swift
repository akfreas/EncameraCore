//
//  AsyncVideoCaptureProcessor.swift
//  Encamera
//
//  Created by Alexander Freas on 01.07.22.
//

import Foundation
import AVFoundation
import Combine

public class AsyncVideoCaptureProcessor: NSObject {
    
    private typealias VideoCaptureProcessorContinuation = CheckedContinuation<CleartextMedia<URL>, Error>
    
    private var continuation: VideoCaptureProcessorContinuation?
    private let captureOutput: AVCaptureMovieFileOutput
    private let durationSubject: PassthroughSubject<CMTime, Never> = .init()
    private var cancellables = Set<AnyCancellable>()

    let videoId = NSUUID().uuidString
    var tempFileUrl: URL {
        URL.tempMediaDirectory
            .appendingPathComponent(videoId)
            .appendingPathExtension("mov")
    }
    
    public var durationPublisher: AnyPublisher<CMTime, Never> {
        durationSubject.eraseToAnyPublisher()
    }
    
    required init(videoCaptureOutput: AVCaptureMovieFileOutput) {
        self.captureOutput = videoCaptureOutput
    }
    
    public func takeVideo() async throws -> CleartextMedia<URL> {
        return try await withCheckedThrowingContinuation({ (continuation: VideoCaptureProcessorContinuation) in
            Task { @MainActor in
                self.durationSubject.send(self.captureOutput.recordedDuration)
            }
            Timer.publish(every: 0.1, on: .main, in: .default).autoconnect().receive(on: DispatchQueue.main).sink { _ in
                self.durationSubject.send(self.captureOutput.recordedDuration)
            }.store(in: &cancellables)
            self.captureOutput.startRecording(to: tempFileUrl, recordingDelegate: self)
            self.continuation = continuation
        })
    }
    
    public func stop() {
        cancellables.forEach({$0.cancel()})
        captureOutput.stopRecording()
    }
    
    
}

extension AsyncVideoCaptureProcessor: AVCaptureFileOutputRecordingDelegate {
    
    
    public func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        debugPrint(outputFileURL)
        
        let cleartextVideo = CleartextMedia(source: outputFileURL, mediaType: .video, id: videoId)
        continuation?.resume(returning: cleartextVideo)
    }
    
    public func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
    }
    
    
}
