import Foundation
import UIKit
import AVFoundation

extension UIDeviceOrientation {
    /// The rotation angle this device orientation implies for a camera whose
    /// sensor is mounted the usual way. `landscapeLeft` maps to 0° (landscape
    /// right in video terms) and vice versa, because the sensor is mounted
    /// rotated relative to the device body.
    ///
    /// Not a general answer, and not the one to reach for: the mounting differs
    /// between the front and back cameras and between device generations, so
    /// this table is wrong for some cameras — which is what left front-camera
    /// captures rotated (ENC-15). `CaptureRotationTracker` asks the camera
    /// itself; this survives only as its fallback on hosts with no camera.
    /// Nil for `faceUp`, `faceDown` and `unknown`, which imply no angle at all.
    public var videoRotationAngle: CGFloat? {
        switch self {
        case .portrait: return 90
        case .portraitUpsideDown: return 270
        case .landscapeLeft: return 0
        case .landscapeRight: return 180
        default: return nil
        }
    }
}

extension AVCaptureDevice.DiscoverySession {
    var uniqueDevicePositionsCount: Int {

        var uniqueDevicePositions = [AVCaptureDevice.Position]()

        for device in devices where !uniqueDevicePositions.contains(device.position) {
            uniqueDevicePositions.append(device.position)
        }

        return uniqueDevicePositions.count
    }
}
