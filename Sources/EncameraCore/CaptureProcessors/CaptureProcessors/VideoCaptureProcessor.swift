//
//  VideoCaptureProcessor.swift
//  Encamera
//
//  Created by Alexander Freas on 18.04.22.
//

import Foundation
import AVFoundation
import Combine
import EncameraCore

class VideoCaptureProcessor: NSObject, CaptureProcessor {
    
    private let fileHandler: FileWriter
    private var cancellables = Set<AnyCancellable>()
    private let completion: (CaptureProcessor) -> (Void)
    let videoId = NSUUID().uuidString
 
    required init(willCapturePhotoAnimation: @escaping () -> Void, completionHandler: @escaping (CaptureProcessor) -> Void, photoProcessingHandler: @escaping (Bool) -> Void, fileWriter: FileWriter) {
        self.fileHandler = fileWriter
        self.completion = completionHandler
    }
    
}

extension VideoCaptureProcessor: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        debugPrint(outputFileURL)
        
        let cleartextVideo = CleartextMedia(source: outputFileURL, mediaType: .video, id: videoId)
        Task {
            try await fileHandler.save(media: cleartextVideo)
            self.completion(self)
        }
    }
    
    
    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        debugPrint(fileURL, connections)
    }
    
}
