import Foundation
import AVFoundation

public protocol CameraConfigurationServicableDelegate {
    func didUpdate(zoomLevels: [ZoomLevel])
    func didUpdate(cameraPosition: AVCaptureDevice.Position)
    /// The camera now feeding the session, whenever it changes. The rotation
    /// angles a connection needs are a property of the specific camera, not of
    /// the session, so whoever tracks them has to be told which device to ask.
    func didUpdate(videoDevice: AVCaptureDevice?)
    func didUpdate(wideBaseZoomFactor: CGFloat)
    func didUpdate(videoZoomFactor: CGFloat)
}
