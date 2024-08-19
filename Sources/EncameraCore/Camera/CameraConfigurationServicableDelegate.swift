import Foundation
import AVFoundation

public protocol CameraConfigurationServicableDelegate {
    func didUpdate(zoomLevels: [ZoomLevel])
    func didUpdate(cameraPosition: AVCaptureDevice.Position)
}
