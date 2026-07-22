import XCTest
import AVFoundation
@testable import EncameraCore

private final class MockZoomableDevice: ZoomableDevice {
    var zoomConstituentDevices: [ConstituentDeviceInfo] = []
    var virtualDeviceSwitchOverVideoZoomFactors: [NSNumber] = []
    var minAvailableVideoZoomFactor: CGFloat = 1.0
    var zoomDeviceActiveFormatVideoMaxZoomFactor: CGFloat = 16.0
    var zoomDeviceActiveFormatSecondaryNativeResolutionZoomFactors: [CGFloat] = []
    var zoomDeviceType: AVCaptureDevice.DeviceType = .builtInWideAngleCamera
    var zoomDeviceLocalizedName: String = "Mock Camera"
    var videoZoomFactor: CGFloat = 1.0

    var lockForConfigurationCallCount = 0
    var unlockForConfigurationCallCount = 0
    var shouldThrowOnLock = false

    func lockForConfiguration() throws {
        lockForConfigurationCallCount += 1
        if shouldThrowOnLock {
            throw NSError(domain: "MockZoomableDevice", code: 1, userInfo: nil)
        }
    }

    func unlockForConfiguration() {
        unlockForConfigurationCallCount += 1
    }
}

private final class MockZoomServiceDelegate: ZoomServiceDelegate {
    var updatedZoomLevels: [ZoomLevel]?
    var updatedWideBaseZoomFactor: CGFloat?
    var updatedVideoZoomFactor: CGFloat?

    func zoomService(_ service: ZoomService, didUpdateZoomLevels levels: [ZoomLevel]) {
        updatedZoomLevels = levels
    }

    func zoomService(_ service: ZoomService, didUpdateWideBaseZoomFactor factor: CGFloat) {
        updatedWideBaseZoomFactor = factor
    }

    func zoomService(_ service: ZoomService, didUpdateVideoZoomFactor factor: CGFloat) {
        updatedVideoZoomFactor = factor
    }
}

final class ZoomServiceTests: XCTestCase {

    private var sut: ZoomService!
    private var mockDevice: MockZoomableDevice!
    private var mockDelegate: MockZoomServiceDelegate!

    override func setUp() {
        super.setUp()
        sut = ZoomService()
        mockDevice = MockZoomableDevice()
        mockDelegate = MockZoomServiceDelegate()
        sut.delegate = mockDelegate
        sut.updateDevice(mockDevice)
    }

    override func tearDown() {
        sut = nil
        mockDevice = nil
        mockDelegate = nil
        super.tearDown()
    }

    // MARK: - Triple Camera Discovery

    func testLoadAvailableZoomFactors_tripleCamera() {
        mockDevice.zoomDeviceType = .builtInTripleCamera
        mockDevice.zoomConstituentDevices = [
            ConstituentDeviceInfo(deviceType: .builtInUltraWideCamera),
            ConstituentDeviceInfo(deviceType: .builtInWideAngleCamera),
            ConstituentDeviceInfo(deviceType: .builtInTelephotoCamera)
        ]
        mockDevice.virtualDeviceSwitchOverVideoZoomFactors = [2, 6]
        mockDevice.minAvailableVideoZoomFactor = 1.0
        mockDevice.zoomDeviceActiveFormatVideoMaxZoomFactor = 16.0
        mockDevice.zoomDeviceActiveFormatSecondaryNativeResolutionZoomFactors = []

        sut.loadAvailableZoomFactors()

        XCTAssertEqual(sut.wideBaseZF, 2.0)
        XCTAssertEqual(sut.zoomFactorMap[.x05], 1.0, "0.5x should map to videoZF 1.0 (ultra-wide)")
        XCTAssertEqual(sut.zoomFactorMap[.x1], 2.0, "1x should map to videoZF 2.0 (wide)")
        XCTAssertEqual(sut.zoomFactorMap[.x3], 6.0, "3x should map to videoZF 6.0 (telephoto)")
        XCTAssertNil(sut.zoomFactorMap[.x2], "2x should not be available without center-crop")
        XCTAssertNil(sut.zoomFactorMap[.x5], "5x should not be available (no native backing)")

        XCTAssertEqual(mockDelegate.updatedWideBaseZoomFactor, 2.0)
        XCTAssertNotNil(mockDelegate.updatedZoomLevels)
        XCTAssertTrue(mockDelegate.updatedZoomLevels!.contains(.x05))
        XCTAssertTrue(mockDelegate.updatedZoomLevels!.contains(.x1))
        XCTAssertTrue(mockDelegate.updatedZoomLevels!.contains(.x3))
    }

    // MARK: - Dual Wide Camera Discovery

    func testLoadAvailableZoomFactors_dualWideCamera() {
        mockDevice.zoomDeviceType = .builtInDualWideCamera
        mockDevice.zoomConstituentDevices = [
            ConstituentDeviceInfo(deviceType: .builtInUltraWideCamera),
            ConstituentDeviceInfo(deviceType: .builtInWideAngleCamera)
        ]
        mockDevice.virtualDeviceSwitchOverVideoZoomFactors = [2]
        mockDevice.minAvailableVideoZoomFactor = 1.0
        mockDevice.zoomDeviceActiveFormatVideoMaxZoomFactor = 16.0
        mockDevice.zoomDeviceActiveFormatSecondaryNativeResolutionZoomFactors = [4]

        sut.loadAvailableZoomFactors()

        XCTAssertEqual(sut.wideBaseZF, 2.0)
        XCTAssertEqual(sut.zoomFactorMap[.x05], 1.0)
        XCTAssertEqual(sut.zoomFactorMap[.x1], 2.0)
        XCTAssertEqual(sut.zoomFactorMap[.x2], 4.0, "2x should be available via center-crop")
        XCTAssertNil(sut.zoomFactorMap[.x3])
        XCTAssertNil(sut.zoomFactorMap[.x5])
    }

    // MARK: - Single Wide Angle Discovery

    func testLoadAvailableZoomFactors_singleWideAngle() {
        mockDevice.zoomDeviceType = .builtInWideAngleCamera
        mockDevice.zoomConstituentDevices = []
        mockDevice.virtualDeviceSwitchOverVideoZoomFactors = []
        mockDevice.minAvailableVideoZoomFactor = 1.0
        mockDevice.zoomDeviceActiveFormatVideoMaxZoomFactor = 10.0
        mockDevice.zoomDeviceActiveFormatSecondaryNativeResolutionZoomFactors = []

        sut.loadAvailableZoomFactors()

        XCTAssertEqual(sut.wideBaseZF, 1.0)
        XCTAssertEqual(sut.zoomFactorMap.count, 1)
        XCTAssertEqual(sut.zoomFactorMap[.x1], 1.0)
    }

    // MARK: - Set Discrete Zoom

    func testSetZoom_appliesCorrectFactor() {
        configureTripleCamera()
        sut.loadAvailableZoomFactors()

        sut.set(zoom: .x1)

        XCTAssertEqual(mockDevice.videoZoomFactor, 2.0, "Should set videoZoomFactor to wideBaseZF (2.0) for 1x")
        XCTAssertEqual(mockDevice.lockForConfigurationCallCount, 1)
        XCTAssertEqual(mockDevice.unlockForConfigurationCallCount, 1)
    }

    func testSetZoom_unavailableLevel() {
        configureTripleCamera()
        sut.loadAvailableZoomFactors()
        mockDevice.videoZoomFactor = 2.0

        sut.set(zoom: .x5)

        XCTAssertEqual(mockDevice.videoZoomFactor, 2.0, "Should not change zoom for unavailable level")
        XCTAssertEqual(mockDevice.lockForConfigurationCallCount, 0, "Should not lock device for unavailable level")
    }

    // MARK: - Continuous Zoom Clamping

    func testSetContinuousZoom_clampsToRange() {
        configureTripleCamera()
        sut.loadAvailableZoomFactors()

        let resultHigh = sut.setContinuousZoom(factor: 100.0)
        XCTAssertEqual(resultHigh, 6.0, "Should clamp to max zoom factor map value")
        XCTAssertEqual(mockDevice.videoZoomFactor, 6.0)

        let resultLow = sut.setContinuousZoom(factor: 0.1)
        XCTAssertEqual(resultLow, 1.0, "Should clamp to min zoom factor map value")
        XCTAssertEqual(mockDevice.videoZoomFactor, 1.0)
    }

    func testSetContinuousZoom_withinRange() {
        configureTripleCamera()
        sut.loadAvailableZoomFactors()

        let result = sut.setContinuousZoom(factor: 3.5)
        XCTAssertEqual(result, 3.5, "Should apply factor as-is when within range")
        XCTAssertEqual(mockDevice.videoZoomFactor, 3.5)
    }

    // MARK: - Nearest Available Zoom Level

    func testNearestAvailableZoomLevel() {
        configureTripleCamera()
        sut.loadAvailableZoomFactors()

        let nearest = sut.nearestAvailableZoomLevel(forVideoZoomFactor: 5.5)
        XCTAssertEqual(nearest, .x3, "5.5 is closest to 6.0 (.x3) vs 2.0 (.x1)")

        let nearestLow = sut.nearestAvailableZoomLevel(forVideoZoomFactor: 1.3)
        XCTAssertEqual(nearestLow, .x05, "1.3 is closest to 1.0 (.x05) vs 2.0 (.x1)")
    }

    func testNearestAvailableZoomLevel_emptyMap() {
        let result = sut.nearestAvailableZoomLevel(forVideoZoomFactor: 2.0)
        XCTAssertNil(result, "Should return nil when zoom factor map is empty")
    }

    // MARK: - Zoom Target (ENC-115)

    func testSetZoom_recordsTarget() {
        configureTripleCamera()
        sut.loadAvailableZoomFactors()

        sut.set(zoom: .x1)

        XCTAssertEqual(sut.targetVideoZoomFactor, 2.0, "A discrete zoom request must become the target")
        XCTAssertEqual(mockDevice.videoZoomFactor, 2.0)
    }

    func testSetContinuousZoom_recordsTarget() {
        configureTripleCamera()
        sut.loadAvailableZoomFactors()

        sut.setContinuousZoom(factor: 3.0)

        XCTAssertEqual(sut.targetVideoZoomFactor, 3.0, "A continuous zoom request must become the target")
        XCTAssertEqual(mockDevice.videoZoomFactor, 3.0)
    }

    func testApplyTarget_restoresAfterExternalReset() {
        configureTripleCamera()
        sut.loadAvailableZoomFactors()
        sut.set(zoom: .x1)
        XCTAssertEqual(mockDevice.videoZoomFactor, 2.0)

        // Simulate AVFoundation resetting the factor (activeFormat change,
        // session reconfiguration) back to the ultra-wide default.
        mockDevice.videoZoomFactor = 1.0

        sut.applyTarget()

        XCTAssertEqual(mockDevice.videoZoomFactor, 2.0, "The configuration-transaction postcondition must restore the target")
    }

    func testApplyTarget_noopWithoutTarget() {
        configureTripleCamera()
        sut.loadAvailableZoomFactors()

        sut.applyTarget()

        XCTAssertEqual(mockDevice.lockForConfigurationCallCount, 0, "No device write before the first zoom request")
        XCTAssertEqual(mockDevice.videoZoomFactor, 1.0)
    }

    func testUpdateDevice_clearsTarget() {
        configureTripleCamera()
        sut.loadAvailableZoomFactors()
        sut.set(zoom: .x1)

        let newDevice = MockZoomableDevice()
        sut.updateDevice(newDevice)
        sut.applyTarget()

        XCTAssertNil(sut.targetVideoZoomFactor, "A device change must clear the previous device's target")
        XCTAssertEqual(newDevice.videoZoomFactor, 1.0, "A stale zoom target must not leak onto a new device")
    }

    // MARK: - Helpers

    private func configureTripleCamera() {
        mockDevice.zoomDeviceType = .builtInTripleCamera
        mockDevice.zoomConstituentDevices = [
            ConstituentDeviceInfo(deviceType: .builtInUltraWideCamera),
            ConstituentDeviceInfo(deviceType: .builtInWideAngleCamera),
            ConstituentDeviceInfo(deviceType: .builtInTelephotoCamera)
        ]
        mockDevice.virtualDeviceSwitchOverVideoZoomFactors = [2, 6]
        mockDevice.minAvailableVideoZoomFactor = 1.0
        mockDevice.zoomDeviceActiveFormatVideoMaxZoomFactor = 16.0
        mockDevice.zoomDeviceActiveFormatSecondaryNativeResolutionZoomFactors = []
    }
}
