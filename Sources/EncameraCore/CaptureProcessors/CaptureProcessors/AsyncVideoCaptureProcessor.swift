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
    
    private typealias VideoCaptureProcessorContinuation = CheckedContinuation<InteractableMedia<CleartextMedia>, Error>

    private var continuation: VideoCaptureProcessorContinuation?
    private let captureOutput: AVCaptureMovieFileOutput
    private let durationSubject: PassthroughSubject<CMTime, Never> = .init()
    private var cancellables = Set<AnyCancellable>()

    let videoId = NSUUID().uuidString
    var tempFileUrl: URL {
        URL.tempRecordingDirectory
            .appendingPathComponent(videoId)
            .appendingPathExtension("mov")
    }
    
    public var durationPublisher: AnyPublisher<CMTime, Never> {
        durationSubject.eraseToAnyPublisher()
    }
    
    required init(videoCaptureOutput: AVCaptureMovieFileOutput) {
        self.captureOutput = videoCaptureOutput
    }
    
    public func takeVideo() async throws -> InteractableMedia<CleartextMedia> {
        NotificationUtils.didEnterBackgroundPublisher.sink { _ in
            self.stop()
        }.store(in: &cancellables)
        NotificationUtils.willResignActivePublisher.sink { _ in
            self.stop()
        }.store(in: &cancellables)
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

        // AVFoundation reports a non-nil error even when the recording is usable
        // (e.g. a clean user-initiated stop) via AVErrorRecordingSuccessfullyFinishedKey.
        // Only treat it as a failure when the recording did not finish successfully —
        // otherwise an interrupted recording was silently saved as a truncated clip.
        if let error = error {
            let finishedSuccessfully = (error as NSError)
                .userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool ?? false
            if !finishedSuccessfully {
                continuation?.resume(throwing: error)
                return
            }
        }

        do {
            let cleartextVideo = try InteractableMedia(underlyingMedia: [CleartextMedia(source: .url(outputFileURL), mediaType: .video, id: videoId)])
            continuation?.resume(returning: cleartextVideo)
        } catch {
            continuation?.resume(throwing: error)
        }
    }
    
    public func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
    }
    
    
}
