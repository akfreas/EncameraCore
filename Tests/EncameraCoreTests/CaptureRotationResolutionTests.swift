//
//  CaptureRotationResolutionTests.swift
//  EncameraCoreTests
//
//  The precedence rule behind ENC-15: the camera's own rotation coordinator is
//  the source of truth for both connections, and the device-orientation guess is
//  only used where no coordinator can exist.
//

import XCTest
@testable import EncameraCore

final class CaptureRotationResolutionTests: XCTestCase {

    // MARK: - Precedence

    /// The whole point of the fix. A camera whose sensor is mounted differently
    /// reports an angle that the device-orientation table does not know about —
    /// front cameras differ from back cameras, and differ again between device
    /// generations — so the hardware answer must win outright.
    func testHardwareAnglesWinOverTheDeviceOrientationFallback() {
        let resolution = CaptureRotationResolution.resolve(hardwarePreview: 0,
                                                           hardwareCapture: 0,
                                                           fallback: 90)
        XCTAssertEqual(resolution.preview, 0)
        XCTAssertEqual(resolution.capture, 0)
        XCTAssertTrue(resolution.isHardwareBacked)
    }

    /// Preview and capture are resolved independently: AVFoundation warns that
    /// the two can legitimately disagree, so collapsing them to one angle would
    /// reintroduce the bug on the other connection.
    func testPreviewAndCaptureAnglesAreResolvedIndependently() {
        let resolution = CaptureRotationResolution.resolve(hardwarePreview: 90,
                                                           hardwareCapture: 180,
                                                           fallback: 270)
        XCTAssertEqual(resolution.preview, 90)
        XCTAssertEqual(resolution.capture, 180)
    }

    /// No preview layer yet means the coordinator reports 0° for preview, which
    /// would show the preview on its side. That case falls back rather than
    /// trusting the 0.
    func testPreviewFallsBackWhileNoPreviewLayerIsAttached() {
        let resolution = CaptureRotationResolution.resolve(hardwarePreview: nil,
                                                           hardwareCapture: 180,
                                                           fallback: 90)
        XCTAssertEqual(resolution.preview, 90, "Preview should use the fallback until a layer is attached")
        XCTAssertEqual(resolution.capture, 180, "Capture does not depend on the preview layer")
        XCTAssertFalse(resolution.isHardwareBacked,
                       "A partially-hardware answer must not be reported as hardware-backed")
    }

    /// The simulator has no capture device, so no coordinator can be built.
    func testBothAnglesFallBackWithNoCaptureDevice() {
        let resolution = CaptureRotationResolution.resolve(hardwarePreview: nil,
                                                           hardwareCapture: nil,
                                                           fallback: 270)
        XCTAssertEqual(resolution.preview, 270)
        XCTAssertEqual(resolution.capture, 270)
        XCTAssertFalse(resolution.isHardwareBacked)
    }

    // MARK: - Normalization

    /// `AVCaptureConnection` accepts only quarter turns and silently keeps its
    /// previous angle when handed anything else — a rotated capture with no
    /// error raised anywhere.
    func testAnglesAreSnappedToTheQuarterTurnsAConnectionAccepts() {
        let cases: [(CGFloat, CGFloat)] = [
            (0, 0), (90, 90), (180, 180), (270, 270),
            (360, 0), (450, 90), (-90, 270), (-360, 0),
            (89.6, 90), (271, 270)
        ]
        for (input, expected) in cases {
            XCTAssertEqual(CaptureRotationResolution.normalized(input), expected,
                           "\(input)° should normalize to \(expected)°")
        }
    }

    func testNonFiniteAnglesFallBackToPortrait() {
        XCTAssertEqual(CaptureRotationResolution.normalized(.nan), 90)
        XCTAssertEqual(CaptureRotationResolution.normalized(.infinity), 90)
    }

    // MARK: - The device-orientation table it replaced

    /// The old mapping stays for the no-camera fallback, so its contract is
    /// still worth pinning — including that a flat or unknown device yields no
    /// angle at all rather than a bogus one.
    func testDeviceOrientationTableMapsOnlyUnambiguousOrientations() {
        XCTAssertEqual(UIDeviceOrientation.portrait.videoRotationAngle, 90)
        XCTAssertEqual(UIDeviceOrientation.portraitUpsideDown.videoRotationAngle, 270)
        XCTAssertEqual(UIDeviceOrientation.landscapeLeft.videoRotationAngle, 0)
        XCTAssertEqual(UIDeviceOrientation.landscapeRight.videoRotationAngle, 180)
        XCTAssertNil(UIDeviceOrientation.faceUp.videoRotationAngle)
        XCTAssertNil(UIDeviceOrientation.faceDown.videoRotationAngle)
        XCTAssertNil(UIDeviceOrientation.unknown.videoRotationAngle)
    }
}
