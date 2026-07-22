import Foundation
import AVFoundation

public enum ZoomLevel: CGFloat {
    case x05 = 0.5
    case x1 = 1.0
    case x2 = 2.0
    case x3 = 3.0
    case x5 = 5.0
}

public protocol ZoomServiceDelegate: AnyObject {
    func zoomService(_ service: ZoomService, didUpdateZoomLevels levels: [ZoomLevel])
    func zoomService(_ service: ZoomService, didUpdateWideBaseZoomFactor factor: CGFloat)
    func zoomService(_ service: ZoomService, didUpdateVideoZoomFactor factor: CGFloat)
}

public class ZoomService: DebugPrintable {

    public private(set) var zoomFactorMap: [ZoomLevel: CGFloat] = [:] {
        didSet {
            guard Set(zoomFactorMap.keys) != Set(oldValue.keys) else { return }
            let sorted = zoomFactorMap.keys.sorted(by: { $0.rawValue < $1.rawValue })
            delegate?.zoomService(self, didUpdateZoomLevels: sorted)
        }
    }

    public private(set) var wideBaseZF: CGFloat = 1.0 {
        didSet {
            guard wideBaseZF != oldValue else { return }
            delegate?.zoomService(self, didUpdateWideBaseZoomFactor: wideBaseZF)
        }
    }

    public weak var delegate: ZoomServiceDelegate?
    private weak var device: ZoomableDevice?
    private var videoZoomFactorObservation: NSKeyValueObservation?
    /// The single source of intent: the videoZoomFactor the app wants the
    /// device to have. AVFoundation resets the device's factor to its default
    /// (the ultra-wide lens on virtual multi-cam devices) on activeFormat and
    /// preset changes, so every configuration transaction ends by applying
    /// this target via `applyTarget()` — device state is a deterministic
    /// function of the last zoom request, never of reset timing.
    public private(set) var targetVideoZoomFactor: CGFloat?

    public init() {}

    public func updateDevice(_ device: ZoomableDevice?) {
        self.device = device
        targetVideoZoomFactor = nil
        observeVideoZoomFactor(of: device)
    }

    /// Logs and forwards every hardware videoZoomFactor change, including ones
    /// this service did not initiate (AVFoundation resets the factor to 1.0 —
    /// the ultra-wide lens on virtual multi-cam devices — when the active
    /// format changes).
    private func observeVideoZoomFactor(of device: ZoomableDevice?) {
        videoZoomFactorObservation = nil
        guard let avDevice = device as? AVCaptureDevice else { return }
        videoZoomFactorObservation = avDevice.observe(\.videoZoomFactor, options: [.initial, .old, .new]) { [weak self] _, change in
            guard let self, let new = change.newValue else { return }
            if let old = change.oldValue {
                self.printDebug("videoZoomFactor changed: \(old) → \(new)")
            } else {
                self.printDebug("videoZoomFactor initial: \(new)")
            }
            self.delegate?.zoomService(self, didUpdateVideoZoomFactor: new)
        }
    }

    // MARK: - Discovery

    public func loadAvailableZoomFactors() {
        guard let device else { return }

        let constituents = device.zoomConstituentDevices
        let switchOverFactors = device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat($0.doubleValue) }
        let minZF = device.minAvailableVideoZoomFactor
        let maxZF = device.zoomDeviceActiveFormatVideoMaxZoomFactor
        let secondaryFactors = device.zoomDeviceActiveFormatSecondaryNativeResolutionZoomFactors

        printDebug("Zoom discovery: \(device.zoomDeviceLocalizedName) (\(device.zoomDeviceType.rawValue)), range: \(minZF)–\(maxZF), switchOvers: \(switchOverFactors)")

        let wideBaseZF: CGFloat
        switch device.zoomDeviceType {
        case .builtInTripleCamera, .builtInDualWideCamera:
            wideBaseZF = switchOverFactors.first ?? 1.0
        default:
            wideBaseZF = 1.0
        }
        self.wideBaseZF = wideBaseZF

        let hasUltraWide = constituents.contains { $0.deviceType == .builtInUltraWideCamera }
        let hasTelephoto = constituents.contains { $0.deviceType == .builtInTelephotoCamera }
        var teleMarketingZoom: CGFloat?
        if hasTelephoto, let lastSO = switchOverFactors.last {
            teleMarketingZoom = lastSO / wideBaseZF
        }

        var factorMap: [ZoomLevel: CGFloat] = [:]
        let allLevels: [ZoomLevel] = [.x05, .x1, .x2, .x3, .x5]

        for level in allLevels {
            let videoZF = wideBaseZF * level.rawValue
            let inRange = videoZF >= minZF && videoZF <= maxZF

            let isNative: Bool
            switch level {
            case .x05:
                isNative = hasUltraWide
            case .x1:
                isNative = true
            case .x2, .x3, .x5:
                let closestTeleLevel = teleMarketingZoom.flatMap { closestZoomLevel(to: $0, from: [.x2, .x3, .x5]) }
                let hasCenterCrop = secondaryFactors.contains { abs($0 - videoZF) < 0.5 }
                isNative = closestTeleLevel == level || hasCenterCrop
            }

            printDebug("\(level.rawValue)x → videoZF=\(videoZF), inRange=\(inRange), isNative=\(isNative)")

            if inRange && isNative {
                factorMap[level] = videoZF
            }
        }

        printDebug("Available zoom levels: \(factorMap.keys.sorted { $0.rawValue < $1.rawValue }.map { "\($0.rawValue)x" })")
        self.zoomFactorMap = factorMap
    }

    // MARK: - Discrete Zoom

    public func set(zoom: ZoomLevel) {
        guard let targetFactor = zoomFactorMap[zoom] else {
            printDebug("Zoom level \(zoom) not available")
            return
        }
        printDebug("Setting zoom \(zoom.rawValue)x → videoZoomFactor=\(targetFactor)")
        targetVideoZoomFactor = targetFactor
        applyTarget()
    }

    // MARK: - Continuous Zoom

    @discardableResult
    public func setContinuousZoom(factor: CGFloat) -> CGFloat {
        guard let device else {
            printDebug("No current camera device available for continuous zoom.")
            return 1.0
        }
        let minFactor = zoomFactorMap.values.min() ?? device.minAvailableVideoZoomFactor
        let maxFactor = zoomFactorMap.values.max() ?? device.zoomDeviceActiveFormatVideoMaxZoomFactor
        let clamped = min(max(factor, minFactor), maxFactor)
        targetVideoZoomFactor = clamped
        applyTarget()
        return clamped
    }

    // MARK: - Target Application

    /// Writes the target zoom to the device. Idempotent; besides running on
    /// every zoom request, this is the mandatory final step of each
    /// configuration transaction (activeFormat/preset changes, session start),
    /// which is what keeps the device factor deterministic across the resets
    /// those transactions cause. A no-op until the first zoom request.
    public func applyTarget() {
        guard let device, targetVideoZoomFactor != nil else { return }
        do {
            try device.lockForConfiguration()
            applyTargetAssumingLock()
            device.unlockForConfiguration()
        } catch {
            printDebug("Error occurred while applying zoom target: \(error)")
        }
    }

    /// Writes the target zoom without taking the configuration lock. For use
    /// inside an existing `lockForConfiguration` block immediately after an
    /// `activeFormat` change: the format change resets `videoZoomFactor` to
    /// the device default (ultra-wide on virtual multi-cam devices), and
    /// restoring it within the same lock keeps the reset from ever reaching
    /// the preview.
    public func applyTargetAssumingLock() {
        guard let device, let target = targetVideoZoomFactor else { return }
        device.videoZoomFactor = min(max(target, device.minAvailableVideoZoomFactor),
                                     device.zoomDeviceActiveFormatVideoMaxZoomFactor)
    }

    // MARK: - Query

    public func currentVideoZoomFactor() -> CGFloat {
        return device?.videoZoomFactor ?? 1.0
    }

    public func nearestAvailableZoomLevel(forVideoZoomFactor factor: CGFloat) -> ZoomLevel? {
        guard !zoomFactorMap.isEmpty else { return nil }
        return zoomFactorMap.min(by: { abs($0.value - factor) < abs($1.value - factor) })?.key
    }

    // MARK: - Private

    func closestZoomLevel(to value: CGFloat, from candidates: [ZoomLevel]) -> ZoomLevel? {
        candidates.min(by: { abs($0.rawValue - value) < abs($1.rawValue - value) })
    }
}
