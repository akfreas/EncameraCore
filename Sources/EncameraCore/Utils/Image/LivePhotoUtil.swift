import Foundation
import PhotosUI
import Photos
import Combine

// Utility class to create Live Photos asynchronously
public class LivePhotoUtility {

    public static func createLivePhoto(from media: InteractableMedia<CleartextMedia>) -> AnyPublisher<PHLivePhoto, Error> {
        let subject = PassthroughSubject<PHLivePhoto, Error>()

        // Save the image and video to the temporary directory
        let tempDir = URL.tempMediaDirectory

        // Define file paths for the image and video
        let imageFileURL = tempDir.appendingPathComponent("\(media.id).jpg")

        // Remove existing files if they exist
        let fileManager = FileManager.default

        if fileManager.fileExists(atPath: imageFileURL.path) {
            do {
                try fileManager.removeItem(at: imageFileURL)
            } catch {
                sendError(error, to: subject)
                return subject.eraseToAnyPublisher()
            }
        }

        // Extract the image and video data from the InteractableMedia instance
        guard let imageData = media.imageData, let videoURL = media.videoURL else {
            let error = NSError(domain: "LivePhotoUtilityError", code: -2, userInfo: [NSLocalizedDescriptionKey: "Image data or video URL missing"])
            sendError(error, to: subject)
            return subject.eraseToAnyPublisher()
        }

        // Convert the image data to UIImage
        guard let image = UIImage(data: imageData) else {
            let error = NSError(domain: "LivePhotoUtilityError", code: -3, userInfo: [NSLocalizedDescriptionKey: "Failed to create UIImage from image data"])
            sendError(error, to: subject)
            return subject.eraseToAnyPublisher()
        }

        // Write the image to the file system
        do {
            try imageData.write(to: imageFileURL)
        } catch {
            sendError(error, to: subject)
            return subject.eraseToAnyPublisher()
        }

        // Request a PHLivePhoto
        PHLivePhoto.request(withResourceFileURLs: [imageFileURL, videoURL], placeholderImage: image, targetSize: image.size, contentMode: .aspectFit) { (livePhoto, info) in
            if let livePhoto = livePhoto {
                sendResult(livePhoto, to: subject)
            } else if let error = info[PHLivePhotoInfoErrorKey] as? Error {
                sendError(error, to: subject)
            } else {
                let error = NSError(domain: "LivePhotoUtilityError", code: -1, userInfo: nil)
                sendError(error, to: subject)
            }
        }

        return subject.eraseToAnyPublisher()
    }

    // Method to create and share a Live Photo
    public static func shareLivePhoto(from media: InteractableMedia<CleartextMedia>, on viewController: UIViewController) -> AnyPublisher<Void, Error> {
        return createLivePhoto(from: media)
            .flatMap { livePhoto -> AnyPublisher<Void, Error> in
                let subject = PassthroughSubject<Void, Error>()
                DispatchQueue.main.async {
                    let activityVC = UIActivityViewController(activityItems: [livePhoto], applicationActivities: nil)
                    activityVC.completionWithItemsHandler = { _, success, _, error in
                        if let error = error {
                            subject.send(completion: .failure(error))
                        } else if success {
                            subject.send(())
                            subject.send(completion: .finished)
                        } else {
                            let error = NSError(domain: "LivePhotoUtilityError", code: -4, userInfo: [NSLocalizedDescriptionKey: "Sharing was canceled"])
                            subject.send(completion: .failure(error))
                        }
                    }
                    viewController.present(activityVC, animated: true, completion: nil)
                }
                return subject.eraseToAnyPublisher()
            }
            .eraseToAnyPublisher()
    }

    // Helper method to send errors through the subject
    private static func sendError(_ error: Error, to subject: PassthroughSubject<PHLivePhoto, Error>) {
        subject.send(completion: .failure(error))
    }

    // Helper method to send results through the subject
    private static func sendResult(_ result: PHLivePhoto, to subject: PassthroughSubject<PHLivePhoto, Error>) {
        subject.send(result)
    }
}

extension InteractableMedia where T == CleartextMedia {
    public func generateLivePhoto() -> AnyPublisher<PHLivePhoto?, Error> {
        guard mediaType == .livePhoto else {
            return Just(nil)
                .setFailureType(to: Error.self)
                .eraseToAnyPublisher()
        }

        // Call the utility function to create the Live Photo from the InteractableMedia instance
        return LivePhotoUtility.createLivePhoto(from: self)
            .map { Optional($0) }
            .eraseToAnyPublisher()
    }
}
