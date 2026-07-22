//
//  CameraConfigurationService.swift
//  Encamera
//
//  Created by Alexander Freas on 01.07.22.
//

import Foundation
import AVFoundation
import Combine

public enum LivePhotoMode {
    case on
    case off
}

public enum DepthDataDeliveryMode {
    case on
    case off
}

public enum SessionSetupResult {
    case authorized
    case notAuthorized
    case setupComplete
    case configurationFailed
    case notDetermined
}

public enum SetupError: Error {
    case defaultVideoDeviceUnavailable
    case defaultAudioDeviceUnavailable
    case couldNotAddVideoInputToSession
    case couldNotAddAudioInputToSession
    case couldNotCreateVideoDeviceInput(avFoundationError: Error)
    case couldNotAddPhotoOutputToSession
    case couldNotAddVideoOutputToSession
}

public enum MediaProcessorError: Error {
    case missingMovieOutput
    case setupIncomplete
}

public enum CaptureMode: Int {
    case photo = 0
    case movie = 1
}

public actor CameraConfigurationService: CameraConfigurationServicable, DebugPrintable {

    public var currentCameraDeviceType: AVCaptureDevice.DeviceType?
    public var currentCameraPosition: AVCaptureDevice.Position = .back {
        didSet {
            Task { @MainActor in
                await delegate?.didUpdate(cameraPosition: currentCameraPosition)
            }
        }
    }
    nonisolated private let canCaptureLivePhotoSubject: CurrentValueSubject<Bool, Never>
    nonisolated public var canCaptureLivePhoto: AnyPublisher<Bool, Never> {
        canCaptureLivePhotoSubject.eraseToAnyPublisher()
    }
    nonisolated private let availableResolutionsSubject: CurrentValueSubject<[PhotoResolution], Never>
    nonisolated public var availableResolutions: AnyPublisher<[PhotoResolution], Never> {
        availableResolutionsSubject.eraseToAnyPublisher()
    }
    nonisolated private let availableVideoQualitiesSubject: CurrentValueSubject<[VideoQualityOption], Never>
    nonisolated public var availableVideoQualities: AnyPublisher<[VideoQualityOption], Never> {
        availableVideoQualitiesSubject.eraseToAnyPublisher()
    }
    nonisolated public let session = AVCaptureSession()
    private let model: CameraConfigurationServiceModel
    var delegate: CameraConfigurationServicableDelegate?
    private var movieOutput: AVCaptureMovieFileOutput?
    private let photoOutput = AVCapturePhotoOutput()
    private var videoDeviceInput: AVCaptureDeviceInput?
    private let zoomService = ZoomService()
    private let deviceTypes: [AVCaptureDevice.DeviceType] = [
        .builtInTripleCamera,
        .builtInDualWideCamera,
        .builtInDualCamera,
        .builtInWideAngleCamera,
        .builtInTelephotoCamera,
        .builtInUltraWideCamera
    ]
    private var cancellables = Set<AnyCancellable>()

    public init(model: CameraConfigurationServiceModel) {
        self.model = model
        self.canCaptureLivePhotoSubject = CurrentValueSubject(model.canCaptureLivePhoto)
        self.availableResolutionsSubject = CurrentValueSubject([])
        self.availableVideoQualitiesSubject = CurrentValueSubject([])
        self.zoomService.delegate = self
    }

    public func currentSetupResult() -> SessionSetupResult {
        model.setupResult
    }

    public func currentRotationAngle() -> CGFloat {
        model.rotationAngle
    }

    public func configure() async {
        registerLifecycleObservers()
        if model.setupResult == .setupComplete {
            printDebug("Starting session from configure()")
            await start()
        } else {
            await self.initialSessionConfiguration()
        }
    }

    /// The app-lifecycle observers are registered exactly once per configure
    /// cycle. Registering them inside `start()`/`stop()` accumulated a fresh
    /// set of sinks on every transition, making the number of handlers that
    /// ran on any lifecycle event depend on history.
    private func registerLifecycleObservers() {
        stopCancellables()
        NotificationUtils.didEnterBackgroundPublisher
            .sink { _ in
                Task {
                    await self.stop(observeRestart: true)
                }
            }.store(in: &cancellables)
        NotificationUtils.willResignActivePublisher
            .sink { _ in
                Task {
                    await self.stop(observeRestart: true)
                }
            }.store(in: &cancellables)
        NotificationUtils.didBecomeActivePublisher
            .sink { _ in
                Task {
                    self.printDebug("Starting session from didBecomeActivePublisher")
                    await self.start()
                }
            }.store(in: &cancellables)
        NotificationUtils.willEnterForegroundPublisher
            .sink { _ in
                Task {
                    self.printDebug("Starting session from willEnterForegroundPublisher")
                    await self.start()
                }
            }.store(in: &cancellables)
    }

    public func setDelegate(_ delegate: CameraConfigurationServicableDelegate) async {
        self.delegate = delegate
    }

    public func checkForPermissions() async {

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            self.model.setupResult = .authorized
        case .notDetermined:

            if await AVCaptureDevice.requestAccess(for: .video) == true {
                self.model.setupResult = .authorized
            } else {
                self.model.setupResult = .notAuthorized
            }

        default:
            model.setupResult = .notAuthorized
        }
    }

    public func stop(observeRestart: Bool) async {
        self.printDebug("Stopping session. ObserveRestart: \(observeRestart)")
        if !observeRestart {
            stopCancellables()
        }

        guard self.session.isRunning, self.model.setupResult == .setupComplete else {
            self.printDebug("Could not stop session, isSessionRunning: \(self.session.isRunning), model.setupResult: \(self.model.setupResult)")
            return
        }

        self.session.stopRunning()

    }

    public func start() async {

        guard !session.isRunning else {
            printDebug("Session is running already")
            return
        }
        guard model.setupResult == .setupComplete else {
            printDebug("Cannot start session, setupResult: \(model.setupResult)")
            return
        }

        printDebug("Calling startRunning, videoZoomFactor=\(zoomService.currentVideoZoomFactor())")
        session.startRunning()
        // Final step of the start transaction: the device must carry the
        // intended zoom whenever the session (re)starts.
        zoomService.applyTarget()
        printDebug("Started running session, videoZoomFactor=\(zoomService.currentVideoZoomFactor())")
    }

    public func focus(at focusPoint: CGPoint) async {
        guard let device = videoDeviceInput?.device else {
            printDebug("Trying to focus, video device is nil")
            return
        }
        do {
            if device.isFocusPointOfInterestSupported {
                try device.lockForConfiguration()
                device.focusPointOfInterest = focusPoint
                device.exposurePointOfInterest = focusPoint
                device.exposureMode = .continuousAutoExposure
                device.focusMode = .continuousAutoFocus
                device.unlockForConfiguration()
            }
        }
        catch {
            printDebug(error.localizedDescription)
        }
    }

    public func setExposureTargetBias(_ bias: Float) async {
        guard let device = videoDeviceInput?.device else {
            printDebug("Trying to set exposure bias, video device is nil")
            return
        }
        do {
            try device.lockForConfiguration()
            let clampedBias = max(device.minExposureTargetBias, min(bias, device.maxExposureTargetBias))
            device.setExposureTargetBias(clampedBias, completionHandler: nil)
            device.unlockForConfiguration()
        } catch {
            printDebug("Failed to set exposure target bias: \(error)")
        }
    }

    public func resetExposureTargetBias() async {
        await setExposureTargetBias(0)
    }

    @discardableResult
    public func setContinuousZoom(factor: CGFloat) async -> CGFloat {
        zoomService.setContinuousZoom(factor: factor)
    }

    public func currentVideoZoomFactor() async -> CGFloat {
        zoomService.currentVideoZoomFactor()
    }

    public func nearestAvailableZoomLevel(forVideoZoomFactor factor: CGFloat) async -> ZoomLevel? {
        zoomService.nearestAvailableZoomLevel(forVideoZoomFactor: factor)
    }

    public func set(rotationAngle: CGFloat) async {
        model.rotationAngle = rotationAngle
    }

    public func set(zoom: ZoomLevel) async {
        zoomService.set(zoom: zoom)
    }

    private func performCameraTransition(to newCamera: AVCaptureDevice) throws {
        let newVideoDeviceInput = try AVCaptureDeviceInput(device: newCamera)

        // Input changes must be wrapped in a configuration transaction; swapping
        // the device input outside begin/commitConfiguration corrupts session state.
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        // Remove the current video device input.
        if let videoDeviceInput = videoDeviceInput {
            session.removeInput(videoDeviceInput)
        }

        // Add the new video device input to the session.
        if session.canAddInput(newVideoDeviceInput) {
            session.addInput(newVideoDeviceInput)
            videoDeviceInput = newVideoDeviceInput
            zoomService.updateDevice(newVideoDeviceInput.device)
        } else if let videoDeviceInput = videoDeviceInput {
            // Re-add the old input if the new input can't be added.
            session.addInput(videoDeviceInput)
        }

        // Handle video stabilization, etc.
        if let connection = photoOutput.connection(with: .video) {
            if connection.isVideoStabilizationSupported {
                connection.preferredVideoStabilizationMode = .auto
            }
        }
    }
    public func flipCameraDevice() async {
        
        guard let currentVideoDevice = self.videoDeviceInput?.device else {
            printDebug("Current video device is nil")
            return
        }
        let currentPosition = currentVideoDevice.position

        let preferredPosition: AVCaptureDevice.Position

        switch currentPosition {
        case .unspecified, .front:
            preferredPosition = .back

        case .back:
            preferredPosition = .front

        @unknown default:
            printDebug("Unknown capture position. Defaulting to back, dual-camera.")
            preferredPosition = .back
        }
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .video,
            position: preferredPosition).devices
        var newVideoDevice: AVCaptureDevice? = nil

        // Prefer virtual devices for the back camera, wide-angle for front.
        let prioritizedTypes: [AVCaptureDevice.DeviceType] = preferredPosition == .back
            ? [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera]
            : [.builtInWideAngleCamera]

        for deviceType in prioritizedTypes {
            if let device = devices.first(where: { $0.deviceType == deviceType }) {
                newVideoDevice = device
                break
            }
        }
        if newVideoDevice == nil {
            newVideoDevice = devices.first
        }

        guard let videoDevice = newVideoDevice else {
            printDebug("New video device is nil")
            return
        }

        currentCameraDeviceType = videoDevice.deviceType
        currentCameraPosition = preferredPosition

        do {
            try performCameraTransition(to: videoDevice)
        } catch {
            printDebug("Error occurred while creating video device input: \(error)")
        }
        zoomService.loadAvailableZoomFactors()
        // A new device starts at the wide (1x) lens; the outputs must be
        // reconfigured for it even though the mode is unchanged.
        zoomService.set(zoom: .x1)
        await configureForMode(targetMode: model.cameraMode, force: true)
    }

    /// Reconfigures outputs and preset for `targetMode` as one transaction.
    /// A no-op when the mode is already active (unless `force`d, e.g. after a
    /// camera flip, where the outputs must be reconfigured for the new device).
    ///
    /// For video, pass the desired `videoQuality` so the switch performs a
    /// single format change: the quality's activeFormat is applied directly
    /// (with the zoom target restored inside the same device lock) instead of
    /// first going through a `.high` preset change — each format change resets
    /// videoZoomFactor to the ultra-wide default and flashes the preview.
    public func configureForMode(targetMode: CameraMode, videoQuality: VideoQualityOption? = nil, force: Bool = false) async {

        guard force || targetMode != model.cameraMode else {
            printDebug("Already configured for mode \(targetMode)")
            return
        }
        printDebug("Configuring for mode \(targetMode), videoZoomFactor before=\(zoomService.currentVideoZoomFactor())")
        session.beginConfiguration()
        do {
            switch targetMode {
            case .photo:
                try addPhotoOutputToSession()
            case .video:
                try addVideoOutputToSession(setPreset: videoQuality == nil)
            }
            model.cameraMode = targetMode
        } catch {
            printDebug("Could not switch to mode \(targetMode)", error)
            self.model.setupResult = .configurationFailed
        }
        session.commitConfiguration()
        if targetMode == .video, let videoQuality {
            applyVideoQuality(videoQuality)
        }
        // Final step of the transaction: preset/output changes reset the
        // device's videoZoomFactor to the ultra-wide default on virtual
        // multi-cam devices, so the intended zoom is applied on the way out.
        zoomService.applyTarget()
        printDebug("Configured for mode \(targetMode), videoZoomFactor after=\(zoomService.currentVideoZoomFactor())")
    }

}

extension CameraConfigurationService {

    public func createVideoProcessor(captureRotationAngle: CGFloat? = nil) async throws -> AsyncVideoCaptureProcessor {
        guard let videoOutput = self.movieOutput else {
            throw MediaProcessorError.missingMovieOutput
        }
        let connection = videoOutput.connection(with: .video)
        let angle = captureRotationAngle ?? model.rotationAngle
        if let connection, connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }

        return AsyncVideoCaptureProcessor(videoCaptureOutput: videoOutput)
    }


    public func createPhotoProcessor(flashMode: AVCaptureDevice.FlashMode, livePhotoEnabled: Bool, captureRotationAngle: CGFloat? = nil, maxPhotoDimensions: CMVideoDimensions? = nil) async throws -> AsyncPhotoCaptureProcessor {
        guard self.model.setupResult != .configurationFailed else {
            printDebug("Could not capture photo")
            throw MediaProcessorError.setupIncomplete
        }

        let angle = captureRotationAngle ?? model.rotationAngle
        if let photoOutputConnection = self.photoOutput.connection(with: .video),
           photoOutputConnection.isVideoRotationAngleSupported(angle) {
            photoOutputConnection.videoRotationAngle = angle
        }
        configurePhotoOutput()

        var validatedDimensions = maxPhotoDimensions
        if let requested = maxPhotoDimensions, let device = videoDeviceInput?.device {
            let supported = device.activeFormat.supportedMaxPhotoDimensions
            let isSupported = supported.contains(where: { $0.width == requested.width && $0.height == requested.height })
            if !isSupported {
                validatedDimensions = nil
                printDebug("Requested maxPhotoDimensions \(requested.width)x\(requested.height) not supported by current device; falling back to photoOutput default")
            }
        }

        return AsyncPhotoCaptureProcessor(output: photoOutput, livePhotoEnabled: livePhotoEnabled, flashMode: flashMode, maxPhotoDimensions: validatedDimensions)
    }

    public nonisolated func toggleTorch(on: Bool) {
        // Toggle the torch on the device that is actually attached to the running
        // session. On hardware that uses a virtual multi-camera input (e.g.
        // .builtInTripleCamera / .builtInDualWideCamera), AVCaptureDevice.default(for: .video)
        // returns a *different* constituent device. Locking that constituent for the
        // torch reconfigures the session and interrupts an in-flight video recording,
        // which is why recording with flash on stopped after ~1 second.
        let device = session.inputs
            .compactMap { ($0 as? AVCaptureDeviceInput)?.device }
            .first(where: { $0.hasMediaType(.video) })
            ?? AVCaptureDevice.default(for: .video)

        guard let device, device.hasTorch else {
            printDebug("Torch is not available")
            return
        }

        do {
            try device.lockForConfiguration()
            device.torchMode = on ? .on : .off
            device.unlockForConfiguration()
        } catch {
            printDebug("Torch could not be used")
        }
    }

}

private extension CameraConfigurationService {

    //  MARK: Session Management



    /// Add photo output to session
    /// Note: must call commit() to session after this
    private func addPhotoOutputToSession() throws {

        if let movieOutput = movieOutput {
            session.removeOutput(movieOutput)
            self.movieOutput = nil
        }
        session.sessionPreset = .photo
        if session.canAddOutput(photoOutput) {
            printDebug("Calling addPhotoOutputToSession")
            session.addOutput(photoOutput)
        }
        configurePhotoOutput()
    }

    private func configurePhotoOutput() {
        photoOutput.maxPhotoQualityPrioritization = .quality
        // Set the photo output's maxPhotoDimensions to the largest supported value
        // so that AVCapturePhotoSettings can request any supported resolution without crashing.
        if let device = videoDeviceInput?.device {
            let supportedDimensions = device.activeFormat.supportedMaxPhotoDimensions
            if let largest = supportedDimensions.max(by: { Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height) }) {
                photoOutput.maxPhotoDimensions = largest
                printDebug("Set photoOutput.maxPhotoDimensions to \(largest.width)x\(largest.height)")
            }
        }
        let canCaptureLivePhoto = photoOutput.isLivePhotoCaptureSupported
        printDebug("canCaptureLivePhoto \(canCaptureLivePhoto)")
        model.canCaptureLivePhoto = canCaptureLivePhoto
        canCaptureLivePhotoSubject.send(canCaptureLivePhoto)
        photoOutput.isLivePhotoCaptureEnabled = canCaptureLivePhoto
        loadAvailablePhotoResolutions()
    }

    private func loadAvailablePhotoResolutions() {
        guard let device = videoDeviceInput?.device else {
            availableResolutionsSubject.send([])
            return
        }
        let supportedDimensions = device.activeFormat.supportedMaxPhotoDimensions
        let resolutions = supportedDimensions
            .map { PhotoResolution(dimensions: $0) }
            .sorted { $0.megapixels < $1.megapixels }
        printDebug("Available photo resolutions: \(resolutions.map { $0.displayLabel })")
        availableResolutionsSubject.send(resolutions)
    }

    private func loadAvailableVideoQualities() {
        guard let device = videoDeviceInput?.device else {
            availableVideoQualitiesSubject.send([])
            return
        }

        var seen = Set<String>()
        var options: [VideoQualityOption] = []

        // Standard video resolutions we care about (height values)
        let targetHeights: Set<Int32> = [720, 1080, 2160]

        for format in device.formats {
            let desc = format.formatDescription
            let dimensions = CMVideoFormatDescriptionGetDimensions(desc)
            let mediaSubType = CMFormatDescriptionGetMediaSubType(desc)

            // Only consider video-range formats (420v = video range YCbCr)
            guard mediaSubType == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
                  mediaSubType == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
                  mediaSubType == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange else {
                continue
            }

            guard targetHeights.contains(dimensions.height) else { continue }

            for range in format.videoSupportedFrameRateRanges {
                let maxFPS = Int(range.maxFrameRate)
                // Only offer standard frame rates
                for fps in [24, 30, 60, 120, 240] {
                    if fps <= maxFPS {
                        let key = "\(dimensions.width)x\(dimensions.height)@\(fps)"
                        if !seen.contains(key) {
                            seen.insert(key)
                            options.append(VideoQualityOption(
                                width: dimensions.width,
                                height: dimensions.height,
                                frameRate: fps
                            ))
                        }
                    }
                }
            }
        }

        options.sort {
            if $0.pixelCount != $1.pixelCount {
                return $0.pixelCount < $1.pixelCount
            }
            return $0.frameRate < $1.frameRate
        }

        printDebug("Available video qualities: \(options.map { $0.displayLabel })")
        availableVideoQualitiesSubject.send(options)
    }

    public func applyVideoQuality(_ option: VideoQualityOption?) {
        guard let device = videoDeviceInput?.device, let option else { return }

        // Find a matching format
        let targetFormat = device.formats.first { format in
            let desc = format.formatDescription
            let dims = CMVideoFormatDescriptionGetDimensions(desc)
            guard dims.width == option.width && dims.height == option.height else { return false }
            return format.videoSupportedFrameRateRanges.contains { range in
                Int(range.maxFrameRate) >= option.frameRate
            }
        }

        guard let format = targetFormat else {
            printDebug("No matching format found for \(option.displayLabel)")
            return
        }

        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(option.frameRate))
        // Re-applying the active format still resets videoZoomFactor and
        // interrupts the preview; the quality sinks fire on every mode switch,
        // so an already-active quality must be a strict no-op.
        guard device.activeFormat != format || device.activeVideoMinFrameDuration != frameDuration else {
            printDebug("Video quality \(option.displayLabel) already active")
            return
        }

        do {
            try device.lockForConfiguration()
            device.activeFormat = format
            device.activeVideoMinFrameDuration = frameDuration
            device.activeVideoMaxFrameDuration = frameDuration
            // The activeFormat change resets videoZoomFactor to the device
            // default (ultra-wide on virtual multi-cam devices); restoring it
            // inside the same lock keeps the reset off the preview.
            zoomService.applyTargetAssumingLock()
            device.unlockForConfiguration()
            printDebug("Applied video quality: \(option.displayLabel), videoZoomFactor after activeFormat change=\(device.videoZoomFactor)")
        } catch {
            printDebug("Failed to apply video quality: \(error)")
        }
    }

    /// Pass `setPreset: false` when a specific video quality's activeFormat
    /// will be applied right after the transaction commits — setting the
    /// `.high` preset first would be a second format change (and a second
    /// zoom reset) for the same mode switch.
    private func addVideoOutputToSession(setPreset: Bool = true) throws {
        printDebug("Calling addVideoOutputToSession")

        let movieOutput = AVCaptureMovieFileOutput()

        guard session.canAddOutput(movieOutput) else {
            throw SetupError.couldNotAddVideoOutputToSession
        }
        session.addOutput(movieOutput)
        if setPreset {
            session.sessionPreset = .high
        }
        if let connection = movieOutput.connection(with: .video) {
            if connection.isVideoStabilizationSupported {
                connection.preferredVideoStabilizationMode = .auto
            }
        }

        self.movieOutput = movieOutput
        loadAvailableVideoQualities()
    }

    private func stopCancellables() {
        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()
    }

    private func setupVideoCaptureDevice() throws {
        session.sessionPreset = .photo

        var defaultVideoDevice: AVCaptureDevice?


        // Try to find a suitable camera among the types
        for cameraType in deviceTypes {
            if let device = AVCaptureDevice.default(cameraType, for: .video, position: currentCameraPosition) {
                defaultVideoDevice = device
                currentCameraDeviceType = cameraType
                break
            }
        }

        guard let videoDevice = defaultVideoDevice else {
            throw SetupError.defaultVideoDeviceUnavailable
        }

        do {
            let videoDeviceInput = try AVCaptureDeviceInput(device: videoDevice)

            if session.canAddInput(videoDeviceInput) {
                session.addInput(videoDeviceInput)
                self.videoDeviceInput = videoDeviceInput
                zoomService.updateDevice(videoDevice)
            } else {
                printDebug("Could not add input to session")
            }
        } catch {
            throw SetupError.couldNotCreateVideoDeviceInput(avFoundationError: error)
        }

    }

    private func setupAudioCaptureDevice() throws {

        guard let audioDevice = AVCaptureDevice.default(for: .audio),
              let audioDeviceInput = try? AVCaptureDeviceInput(device: audioDevice)else {
            return
        }

        if session.canAddInput(audioDeviceInput) {
            session.addInput(audioDeviceInput)
        }
    }

    private func initialSessionConfiguration() async {
        guard model.setupResult == .authorized else {
            return
        }
        do {
            session.beginConfiguration()
            defer {
                session.commitConfiguration()
            }
            // There is an unhandled case here, where if the video input
            // cannot be added to the session, it fails but does nothing
            try setupVideoCaptureDevice()
            try setupAudioCaptureDevice()
            try addPhotoOutputToSession()
        } catch {
            printDebug(error)
            return
        }
        model.setupResult = .setupComplete

        // Land on the wide (1x) lens before the session starts: on virtual
        // multi-cam devices the default videoZoomFactor 1.0 is the ultra-wide
        // lens, so the first preview frames would otherwise be 0.5x. Discovery
        // only reads static device/format properties, so both calls are safe
        // while the session is not yet running.
        zoomService.loadAvailableZoomFactors()
        zoomService.set(zoom: .x1)

        // Video qualities also derive from static device formats. Publishing
        // them now means a quality is already selected before the first
        // photo→video switch, so that switch can apply the quality's format
        // directly instead of first falling back to the `.high` preset — a
        // second format change and a second zoom reset.
        loadAvailableVideoQualities()

        printDebug("Initial session configuration committed, videoZoomFactor=\(zoomService.currentVideoZoomFactor())")
        printDebug("Starting session from initialSessionConfiguration")
        await start()
    }

}

extension CameraConfigurationService: ZoomServiceDelegate {
    nonisolated public func zoomService(_ service: ZoomService, didUpdateZoomLevels levels: [ZoomLevel]) {
        Task { @MainActor in
            await self.delegate?.didUpdate(zoomLevels: levels)
        }
    }

    nonisolated public func zoomService(_ service: ZoomService, didUpdateWideBaseZoomFactor factor: CGFloat) {
        Task { @MainActor in
            await self.delegate?.didUpdate(wideBaseZoomFactor: factor)
        }
    }

    nonisolated public func zoomService(_ service: ZoomService, didUpdateVideoZoomFactor factor: CGFloat) {
        Task { @MainActor in
            await self.delegate?.didUpdate(videoZoomFactor: factor)
        }
    }
}
