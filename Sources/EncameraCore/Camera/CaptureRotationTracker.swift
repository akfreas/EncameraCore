//
//  CaptureRotationTracker.swift
//  EncameraCore
//
//  The rotation angles the *active camera* needs for horizon-level preview and
//  capture — asked of the hardware instead of guessed from device orientation.
//

import AVFoundation
import Combine
import Foundation
import QuartzCore
#if canImport(UIKit)
import UIKit
#endif

/// The angles to apply to the preview and capture connections, and where they
/// came from.
///
/// Split out from `CaptureRotationTracker` so the precedence rule — hardware
/// wins, the device-orientation guess is only a last resort — is testable
/// without a camera.
public struct CaptureRotationResolution: Equatable {

    /// Angle for the preview layer's connection.
    public let preview: CGFloat
    /// Angle for the photo and movie output connections.
    public let capture: CGFloat
    /// True when both angles came from the camera's rotation coordinator.
    public let isHardwareBacked: Bool

    public init(preview: CGFloat, capture: CGFloat, isHardwareBacked: Bool) {
        self.preview = preview
        self.capture = capture
        self.isHardwareBacked = isHardwareBacked
    }

    /// Resolves the angles to apply.
    ///
    /// `hardwarePreview` is nil when no preview layer has been handed over yet:
    /// a coordinator built without one reports 0° for preview, and applying that
    /// would leave the preview lying on its side. `hardwareCapture` is nil only
    /// when there is no capture device at all (the simulator).
    public static func resolve(hardwarePreview: CGFloat?,
                               hardwareCapture: CGFloat?,
                               fallback: CGFloat) -> CaptureRotationResolution {
        let safeFallback = normalized(fallback)
        return CaptureRotationResolution(
            preview: hardwarePreview.map(normalized) ?? safeFallback,
            capture: hardwareCapture.map(normalized) ?? safeFallback,
            isHardwareBacked: hardwarePreview != nil && hardwareCapture != nil
        )
    }

    /// Snaps an angle into the 0/90/180/270 set `AVCaptureConnection` accepts.
    /// A connection silently keeps its previous angle when handed an
    /// unsupported one, which is a rotated capture with no error anywhere.
    static func normalized(_ angle: CGFloat) -> CGFloat {
        guard angle.isFinite else { return 90 }
        let wrapped = angle.truncatingRemainder(dividingBy: 360)
        let positive = wrapped < 0 ? wrapped + 360 : wrapped
        let quarter = (positive / 90).rounded()
        return quarter.truncatingRemainder(dividingBy: 4) * 90
    }
}

/// Publishes the video rotation angles for the camera that is currently active.
///
/// Why this exists rather than a table keyed on `UIDevice.current.orientation`:
/// the angle a connection needs is not a property of how the user is holding
/// the phone alone. It also depends on how that particular camera's sensor is
/// mounted, and AVFoundation states plainly that "the video rotation angle for
/// capture may differ between cameras" and that the preview angle "may not match
/// the amount of rotation needed for horizon-level capture". A single
/// hand-rolled angle applied to both connections on both cameras is therefore
/// only accidentally right — it is what left front-camera captures rotated
/// (ENC-15) while the back camera looked fine.
///
/// `AVCaptureDevice.RotationCoordinator` is the API that knows the mounting, so
/// it is the source of truth here. The device-orientation angle survives only as
/// a fallback for hosts with no capture device to build a coordinator from.
@MainActor
public final class CaptureRotationTracker: ObservableObject {

    /// Angle for the preview layer's connection.
    @Published public private(set) var previewAngle: CGFloat = 90
    /// Angle for the photo and movie output connections.
    @Published public private(set) var captureAngle: CGFloat = 90
    /// True while the published angles come from the camera's rotation
    /// coordinator. Read by the on-device orientation suite, which asserts the
    /// applied angle against the hardware's own answer.
    @Published public private(set) var isHardwareBacked = false

    /// The position of the camera the angles describe, for diagnostics.
    public private(set) var cameraPosition: AVCaptureDevice.Position = .unspecified

    private var coordinator: AVCaptureDevice.RotationCoordinator?
    private var observations: [NSKeyValueObservation] = []
    private weak var device: AVCaptureDevice?
    private weak var previewLayer: CALayer?

    private var isObservingOrientation = false

    /// Deliberately does no work: the tracker is created wherever the camera
    /// model is, which is not the main actor, and every angle it publishes is
    /// main-actor state. `activate()` does the setup.
    public nonisolated init() {}

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Starts tracking. Idempotent, so every entry point that could be first —
    /// the preview appearing, the session reporting its camera — can call it.
    public func activate() {
        guard !isObservingOrientation else { return }
        isObservingOrientation = true
#if canImport(UIKit)
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(deviceOrientationDidChange),
            name: UIDevice.orientationDidChangeNotification,
            object: nil
        )
#endif
        publishAngles()
    }

    /// Points the tracker at the camera now feeding the session. Called on the
    /// initial configuration and again on every flip — a coordinator is bound to
    /// one device, so a stale one would keep answering for the camera the user
    /// just switched away from.
    public func attach(device: AVCaptureDevice?) {
        activate()
        guard device !== self.device else { return }
        self.device = device
        cameraPosition = device?.position ?? .unspecified
        rebuildCoordinator()
    }

    /// Hands over the layer showing the preview. Required: a coordinator built
    /// without a layer — or with one that is not yet in a view hierarchy —
    /// reports 0° for preview, so the caller must attach the layer only once it
    /// is on screen.
    public func attach(previewLayer: CALayer?) {
        activate()
        guard previewLayer !== self.previewLayer else { return }
        self.previewLayer = previewLayer
        rebuildCoordinator()
    }

    /// Re-reads the coordinator. The coordinator is key-value observed, but a
    /// layer joining the view hierarchy changes the preview angle without any
    /// rotation happening, so the preview controller re-reads on appearance.
    public func refresh() {
        publishAngles()
    }

    private func rebuildCoordinator() {
        observations.removeAll()
        guard let device else {
            coordinator = nil
            publishAngles()
            return
        }
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        self.coordinator = coordinator
        // Delivered on the main queue, per AVCaptureDeviceRotationCoordinator.
        observations = [
            coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.initial, .new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.publishAngles() }
            },
            coordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.initial, .new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.publishAngles() }
            }
        ]
        publishAngles()
    }

    private func publishAngles() {
        let resolution = CaptureRotationResolution.resolve(
            hardwarePreview: previewLayer == nil ? nil : coordinator?.videoRotationAngleForHorizonLevelPreview,
            hardwareCapture: coordinator?.videoRotationAngleForHorizonLevelCapture,
            fallback: Self.orientationFallbackAngle(current: captureAngle)
        )
        if previewAngle != resolution.preview { previewAngle = resolution.preview }
        if captureAngle != resolution.capture { captureAngle = resolution.capture }
        if isHardwareBacked != resolution.isHardwareBacked { isHardwareBacked = resolution.isHardwareBacked }
    }

    @objc private func deviceOrientationDidChange() {
        publishAngles()
    }

    /// The pre-coordinator behaviour, kept only for hosts without a camera:
    /// map the device orientation, and hold the last angle when the device is
    /// flat or its orientation is unknown.
    private static func orientationFallbackAngle(current: CGFloat) -> CGFloat {
#if canImport(UIKit)
        return UIDevice.current.orientation.videoRotationAngle ?? current
#else
        return current
#endif
    }
}
