//
//  AsyncPhotoCaptureProcessor.swift
//  Encamera
//
//  Created by Alexander Freas on 01.07.22.
//

import Foundation

import Foundation
import AVFoundation
import CoreImage
import Combine

public struct PhotoCaptureProcessorOutput {
    public var photo: CleartextMedia?
    public var livePhoto: CleartextMedia?
}

public class AsyncPhotoCaptureProcessor: NSObject {
    
    private typealias PhotoCaptureProcessorContinuation = CheckedContinuation<PhotoCaptureProcessorOutput, Error>
    
    private(set) var requestedPhotoSettings: AVCapturePhotoSettings
    private weak var photoOutput: AVCapturePhotoOutput?

    private var photoId: String = NSUUID().uuidString
    private var maxPhotoProcessingTime: CMTime?
    private var continuation: PhotoCaptureProcessorContinuation?
    private var currentOutput = PhotoCaptureProcessorOutput()
    private var tempFileUrl: URL {
        URL.tempMediaDirectory
            .appendingPathComponent(photoId)
            .appendingPathExtension("mov")
    }

    init(output photoOutput: AVCapturePhotoOutput, livePhotoEnabled: Bool, flashMode: AVCaptureDevice.FlashMode) {
        self.photoOutput = photoOutput

        var photoSettings = AVCapturePhotoSettings()
        

        photoSettings.flashMode = flashMode
        photoSettings.isHighResolutionPhotoEnabled = true

        self.requestedPhotoSettings = photoSettings
        super.init()

        if livePhotoEnabled {
            photoSettings.livePhotoMovieFileURL = tempFileUrl
        }
    }
    
    public func takePhoto() async throws -> PhotoCaptureProcessorOutput {
        return try await withCheckedThrowingContinuation({ (continuation: PhotoCaptureProcessorContinuation) in
            guard let photoOutput, photoOutput.connections.count > 0 else {
                continuation.resume(returning: PhotoCaptureProcessorOutput())
                return
            }
            self.continuation = continuation
            photoOutput.capturePhoto(with: self.requestedPhotoSettings, delegate: self)
            
        })
    }

}

extension AsyncPhotoCaptureProcessor: AVCapturePhotoCaptureDelegate {
    
    
    
    // This extension adopts AVCapturePhotoCaptureDelegate protocol methods.
    
    /// - Tag: WillBeginCapture
    public func photoOutput(_ output: AVCapturePhotoOutput, willBeginCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings) {

        maxPhotoProcessingTime = resolvedSettings.photoProcessingTimeRange.start + resolvedSettings.photoProcessingTimeRange.duration
    }
    
    
    /// - Tag: DidFinishProcessingPhoto
    public func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error = error {
            debugPrint("Error capturing photo: \(error)")
        } else if let photoData = photo.fileDataRepresentation() {
            currentOutput.photo = CleartextMedia(source: .data(photoData), mediaType: .photo, id: photoId)
        }
    }
    
    public func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingLivePhotoToMovieFileAt outputFileURL: URL, duration: CMTime, photoDisplayTime: CMTime, resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        
        let media = CleartextMedia(source: .url(outputFileURL), mediaType: .video, id: photoId)
        currentOutput.livePhoto = media
    }
    
    
    
    /// - Tag: DidFinishCapture
    public func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        if let error = error {
            continuation?.resume(throwing: error)
            return
        } else {
            continuation?.resume(returning: currentOutput)
        }
    }
}
