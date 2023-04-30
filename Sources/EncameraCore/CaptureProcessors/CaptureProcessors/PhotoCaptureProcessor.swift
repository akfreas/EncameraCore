import Foundation
import AVFoundation
import CoreImage
import Combine
import EncameraCore

class PhotoCaptureProcessor: NSObject, CaptureProcessor {
    
    
    lazy var context = CIContext()

    private(set) var requestedPhotoSettings: AVCapturePhotoSettings!
    
    private let willCapturePhotoAnimation: () -> Void
    
    private let completionHandler: (CaptureProcessor) -> Void
    
    private let photoProcessingHandler: (Bool) -> Void
    
    var photoData: Data?
    var photoId: String
    private var maxPhotoProcessingTime: CMTime?
    private var fileWriter: FileWriter
    private var cancellables = Set<AnyCancellable>()
    
    convenience init(with requestedPhotoSettings: AVCapturePhotoSettings,
                     willCapturePhotoAnimation: @escaping () -> Void,
                     completionHandler: @escaping (CaptureProcessor) -> Void,
                     photoProcessingHandler: @escaping (Bool) -> Void,
                     fileWriter: FileWriter) {
        self.init(
            willCapturePhotoAnimation: willCapturePhotoAnimation,
            completionHandler: completionHandler,
            photoProcessingHandler: photoProcessingHandler,
            fileWriter: fileWriter)
        self.requestedPhotoSettings = requestedPhotoSettings
        
    }
    
    required init(willCapturePhotoAnimation: @escaping () -> Void, completionHandler: @escaping (CaptureProcessor) -> Void, photoProcessingHandler: @escaping (Bool) -> Void, fileWriter: FileWriter) {
        photoId = NSUUID().uuidString
        self.fileWriter = fileWriter
        self.willCapturePhotoAnimation = willCapturePhotoAnimation
        self.completionHandler = completionHandler
        self.photoProcessingHandler = photoProcessingHandler
    }
}

extension PhotoCaptureProcessor: AVCapturePhotoCaptureDelegate {
    
    
    
    // This extension adopts AVCapturePhotoCaptureDelegate protocol methods.
    
    /// - Tag: WillBeginCapture
    func photoOutput(_ output: AVCapturePhotoOutput, willBeginCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings) {

        maxPhotoProcessingTime = resolvedSettings.photoProcessingTimeRange.start + resolvedSettings.photoProcessingTimeRange.duration
    }
    
    /// - Tag: WillCapturePhoto
    func photoOutput(_ output: AVCapturePhotoOutput, willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        DispatchQueue.main.async {
            self.willCapturePhotoAnimation()
        }
        
        guard let maxPhotoProcessingTime = maxPhotoProcessingTime else {
            return
        }
        
        // Show a spinner if processing time exceeds one second.
        let oneSecond = CMTime(seconds: 2, preferredTimescale: 1)
        if maxPhotoProcessingTime > oneSecond {
            DispatchQueue.main.async {
                self.photoProcessingHandler(true)
            }
        }
    }
    
    /// - Tag: DidFinishProcessingPhoto
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        
        DispatchQueue.main.async {
            self.photoProcessingHandler(false)
        }
        
        if let error = error {
            debugPrint("Error capturing photo: \(error)")
        } else {
            photoData = photo.fileDataRepresentation()
        }
    }
    
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingLivePhotoToMovieFileAt outputFileURL: URL, duration: CMTime, photoDisplayTime: CMTime, resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        
        let media = CleartextMedia(source: outputFileURL, mediaType: .video, id: photoId)
        Task {
            _ = try await fileWriter.save(media: media)
            self.completionHandler(self)
        }

    }
    
    
    
    /// - Tag: DidFinishCapture
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        if let error = error {
            debugPrint("Error capturing photo: \(error)")
            DispatchQueue.main.async {
                self.completionHandler(self)
            }
            return
        } else {
            guard let data = photoData else {
                DispatchQueue.main.async {
                    self.completionHandler(self)
                }
                return
            }
            let media = CleartextMedia(source: data, mediaType: .photo, id: photoId)
            Task {
                try await fileWriter.save(media: media)
                self.completionHandler(self)
            }
        }
    }
}
