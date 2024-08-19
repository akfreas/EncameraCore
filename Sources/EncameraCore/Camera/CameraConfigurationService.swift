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
    case couldNotAddMetadataOutputToSession
}

public enum MediaProcessorError: Error {
    case missingMovieOutput
    case setupIncomplete
}

public enum CaptureMode: Int {
    case photo = 0
    case movie = 1
}

public enum ZoomLevel: CGFloat {
    case x05 = 0.5
    case x1 = 1.0
    case x2 = 2.0
    case x3 = 3.0
    case x5 = 5.0
}

fileprivate struct ZoomControlModel {


    var zoomLevel: ZoomLevel = .x1
    var captureDevice: AVCaptureDevice?
    var useDigitalZoom: Bool = false
    public init(zoomLevel: ZoomLevel, captureDevice: AVCaptureDevice? = nil, useDigitalZoom: Bool) {
        self.zoomLevel = zoomLevel
        self.captureDevice = captureDevice
        self.useDigitalZoom = useDigitalZoom
    }
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
    nonisolated public var canCaptureLivePhoto: Published<Bool>.Publisher {
        model.$canCaptureLivePhoto
    }
    nonisolated public let session = AVCaptureSession()
    public let model: CameraConfigurationServiceModel
    var delegate: CameraConfigurationServicableDelegate?
    private var availableZoomFactors: [CGFloat] = [1.0]
    private var availableCameras: [AVCaptureDevice] = []
    private var selectedCamera: AVCaptureDevice?
    private var zoomLevels: [ZoomLevel: ZoomControlModel] = [:] {
        didSet {
            Task { @MainActor in
                await delegate?.didUpdate(zoomLevels: zoomLevels.keys.sorted(by: { $0.rawValue < $1.rawValue }))
            }
        }
    }

    private lazy var metadataProcessor = QRCodeCaptureProcessor()
    private var movieOutput: AVCaptureMovieFileOutput?
    private let photoOutput = AVCapturePhotoOutput()
    private var videoDeviceInput: AVCaptureDeviceInput?
    private let deviceTypes: [AVCaptureDevice.DeviceType] = [
        .builtInDualCamera,
        .builtInWideAngleCamera,
        .builtInDualWideCamera,
        .builtInTelephotoCamera,
        .builtInUltraWideCamera
    ]
    private var cancellables = Set<AnyCancellable>()

    public init(model: CameraConfigurationServiceModel) {
        self.model = model
    }

    public func configure() async {
        if model.setupResult == .setupComplete {
            printDebug("Starting session from configure()")
            await start()
        } else {
            await self.initialSessionConfiguration()
        }
        metadataProcessor.$lastCaptured.sink { qrCodeContents in
            self.printDebug("Got QR Code: \(String(describing: qrCodeContents))")
            guard let contents = qrCodeContents, let url = URL(string: contents) else {
                return
            }

            let type = URLType(url: url)
            switch type {
            case .featureToggle(feature: .stopTracking):
                FeatureToggle.enable(feature: .stopTracking)
            default:
                break
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
        self.stopCancellables()
        if observeRestart {
            NotificationUtils.didBecomeActivePublisher
                .sink { _ in
                    Task {
                        self.printDebug("Starting session from didBecomeActivePublisher")
                        await self.start()
                    }
                }.store(in: &self.cancellables)
            NotificationUtils.willEnterForegroundPublisher
                .sink { _ in
                    Task {
                        self.printDebug("Starting session from willEnterForegroundPublisher")
                        await self.start()
                    }
                }.store(in: &self.cancellables)
        } else {
            cancellables.forEach({ $0.cancel() })
            cancellables.removeAll()
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

        NotificationUtils.cameraDidStartRunningPublisher.sink { value in
            Task { @MainActor in
                await self.loadAvailableZoomFactors()
            }
        }.store(in: &cancellables)

        switch model.setupResult {
        case .setupComplete:
            session.startRunning()
            printDebug("Started running session")
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
            guard session.isRunning else {
                printDebug("Session is not running")
                return
            }
        default:
            fatalError()
        }
    }

    func focus(at focusPoint: CGPoint) async {
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


    func loadAvailableZoomFactors() async {

        let videoDeviceDiscoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes:
                deviceTypes, mediaType: .video, position: currentCameraPosition)
        var zoomLevelsDict: [ZoomLevel: ZoomControlModel] = [:]

        for camera in videoDeviceDiscoverySession.devices {
            let maxZoomFactor = camera.maxAvailableVideoZoomFactor

            switch camera.deviceType {
            case .builtInUltraWideCamera:
                if maxZoomFactor >= ZoomLevel.x05.rawValue {
                    zoomLevelsDict[.x05] = ZoomControlModel(zoomLevel: .x05, captureDevice: camera, useDigitalZoom: false)
                }
            case .builtInWideAngleCamera:
                if maxZoomFactor >= ZoomLevel.x1.rawValue {
                    zoomLevelsDict[.x1] = ZoomControlModel(zoomLevel: .x1, captureDevice: camera, useDigitalZoom: false)
                }
                if maxZoomFactor >= ZoomLevel.x2.rawValue {
                    zoomLevelsDict[.x2] = ZoomControlModel(zoomLevel: .x2, captureDevice: camera, useDigitalZoom: true)
                }
            case .builtInTelephotoCamera:
                if maxZoomFactor >= ZoomLevel.x5.rawValue {
                    zoomLevelsDict[.x5] = ZoomControlModel(zoomLevel: .x5, captureDevice: camera, useDigitalZoom: false)
                } else if maxZoomFactor >= ZoomLevel.x3.rawValue {
                    zoomLevelsDict[.x3] = ZoomControlModel(zoomLevel: .x3, captureDevice: camera, useDigitalZoom: false)
                }

            default:
                break
            }
        }
        self.zoomLevels = zoomLevelsDict
    }

    public func set(rotation: AVCaptureVideoOrientation) async {
        model.orientation = rotation
    }

    public func set(zoom: ZoomLevel) async {

        // Find the camera device for the given zoom level.
        guard let zoomLevel = zoomLevels[zoom], let newCamera = zoomLevel.captureDevice else {
            printDebug("No camera available for the given zoom level: \(zoom)")
            return
        }

        // Check if the selected camera is different from the current one.
        if newCamera != videoDeviceInput?.device {
            do {
                let newVideoDeviceInput = try AVCaptureDeviceInput(device: newCamera)

                // Remove the current video device input from the session.
                if let videoDeviceInput = videoDeviceInput {
                    session.removeInput(videoDeviceInput)
                }

                // Add the new video device input to the session.
                if session.canAddInput(newVideoDeviceInput) {
                    self.session.addInput(newVideoDeviceInput)
                    self.videoDeviceInput = newVideoDeviceInput
                } else if let videoDeviceInput = self.videoDeviceInput {
                    // Re-add the old input if the new input can't be added.
                    self.session.addInput(videoDeviceInput)
                }

                // Set the video stabilization mode if supported.
                if let connection = self.photoOutput.connection(with: .video) {
                    if connection.isVideoStabilizationSupported {
                        connection.preferredVideoStabilizationMode = .auto
                    }
                }
            } catch {
                printDebug("Error occurred while switching video device input: \(error)")
                return
            }
        }

        do {
            try newCamera.lockForConfiguration()

            // Set the optical zoom if the zoom level is not digital.
            if !zoomLevel.useDigitalZoom {
                newCamera.videoZoomFactor = 1.0
            } else {
                // Adjust digital zoom factor, considering the optical zoom factor.
                let currentZoomFactor = newCamera.videoZoomFactor
                let targetZoomFactor = CGFloat(zoom.rawValue)

                if targetZoomFactor > currentZoomFactor {
                    newCamera.videoZoomFactor = targetZoomFactor
                } else {
                    // For cases where we switch to a lesser zoom level, reset to 1x first, then apply digital zoom
                    newCamera.videoZoomFactor = 1.0
                    newCamera.videoZoomFactor = targetZoomFactor
                }
            }

            newCamera.unlockForConfiguration()
        } catch {
            printDebug("Error occurred while setting video zoom factor: \(error)")
            return
        }
    }

    public func flipCameraDevice() async {
        
        guard let currentVideoDevice = self.videoDeviceInput?.device else {
            printDebug("Current video device is nil")
            return
        }
        let currentPosition = currentVideoDevice.position

        let preferredPosition: AVCaptureDevice.Position
        let preferredDeviceType: AVCaptureDevice.DeviceType

        switch currentPosition {
        case .unspecified, .front:
            preferredPosition = .back
            preferredDeviceType = .builtInWideAngleCamera

        case .back:
            preferredPosition = .front
            preferredDeviceType = .builtInWideAngleCamera

        @unknown default:
            printDebug("Unknown capture position. Defaulting to back, dual-camera.")
            preferredPosition = .back
            preferredDeviceType = .builtInWideAngleCamera
        }
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .video,
            position: preferredPosition).devices
        var newVideoDevice: AVCaptureDevice? = nil

        // First, seek a device with both the preferred position and device type. Otherwise, seek a device with only the preferred position.
        if let device = devices.first(where: { $0.position == preferredPosition && $0.deviceType == preferredDeviceType }) {
            newVideoDevice = device
        } else if let device = devices.first(where: { $0.position == preferredPosition }) {
            newVideoDevice = device
        }

        guard let videoDevice = newVideoDevice else {
            printDebug("New video device is nil")
            return
        }

        currentCameraDeviceType = preferredDeviceType
        currentCameraPosition = preferredPosition

        do {
            let newVideoDeviceInput = try AVCaptureDeviceInput(device: videoDevice)


            if let videoDeviceInput = self.videoDeviceInput {
                session.removeInput(videoDeviceInput)
            }

            if session.canAddInput(newVideoDeviceInput) {
                session.addInput(newVideoDeviceInput)
                videoDeviceInput = newVideoDeviceInput

            } else if let videoDeviceInput = videoDeviceInput {
                session.addInput(videoDeviceInput)
            }

            if let connection = photoOutput.connection(with: .video) {
                if connection.isVideoStabilizationSupported {
                    connection.preferredVideoStabilizationMode = .auto
                }
            }
        } catch {
            printDebug("Error occurred while creating video device input: \(error)")
        }
        await loadAvailableZoomFactors()
        await configureForMode(targetMode: model.cameraMode)
    }

    public func configureForMode(targetMode: CameraMode) async {
        session.beginConfiguration()
        defer {
            session.commitConfiguration()
        }
        printDebug("Configuring for mode \(targetMode)")
        do {
            switch targetMode {
            case .photo:
                try self.addPhotoOutputToSession()
            case .video:
                try self.addVideoOutputToSession()
            }

        } catch {
            printDebug("Could not switch to mode \(targetMode)", error)
            self.model.setupResult = .configurationFailed
        }
    }

}

extension CameraConfigurationService {

    public func createVideoProcessor() async throws -> AsyncVideoCaptureProcessor {
        guard let videoOutput = self.movieOutput else {
            throw MediaProcessorError.missingMovieOutput
        }
        let connection = videoOutput.connection(with: .video)
        connection?.videoOrientation = model.orientation


        return AsyncVideoCaptureProcessor(videoCaptureOutput: videoOutput)
    }


    public func createPhotoProcessor(flashMode: AVCaptureDevice.FlashMode, livePhotoEnabled: Bool) async throws -> AsyncPhotoCaptureProcessor {
        guard self.model.setupResult != .configurationFailed else {
            printDebug("Could not capture photo")
            throw MediaProcessorError.setupIncomplete
        }

        if let photoOutputConnection = self.photoOutput.connection(with: .video) {
            photoOutputConnection.videoOrientation = model.orientation
        }

        return AsyncPhotoCaptureProcessor(output: photoOutput, livePhotoEnabled: livePhotoEnabled, flashMode: flashMode)
    }

    public nonisolated func toggleTorch(on: Bool) {
        guard let device = AVCaptureDevice.default(for: .video) else { return }

        if device.hasTorch {
            do {
                try device.lockForConfiguration()

                if on == true {
                    device.torchMode = .on
                } else {
                    device.torchMode = .off
                }

                device.unlockForConfiguration()
            } catch {
                printDebug("Torch could not be used")
            }
        } else {
            printDebug("Torch is not available")
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
        photoOutput.maxPhotoQualityPrioritization = .quality
        photoOutput.isHighResolutionCaptureEnabled = true
        let canCaptureLivePhoto = photoOutput.isLivePhotoCaptureSupported
        model.canCaptureLivePhoto = canCaptureLivePhoto
        photoOutput.isLivePhotoCaptureEnabled = canCaptureLivePhoto
        guard session.canAddOutput(photoOutput) else {
            printDebug("Could not add photooutput to session")
            return
        }
        printDebug("Calling addPhotoOutputToSession")

        session.addOutput(photoOutput)

    }

    private func addVideoOutputToSession() throws {
        printDebug("Calling addVideoOutputToSession")

        let movieOutput = AVCaptureMovieFileOutput()

        guard session.canAddOutput(movieOutput) else {
            throw SetupError.couldNotAddVideoOutputToSession
        }
        session.addOutput(movieOutput)
        session.sessionPreset = .high
        if let connection = movieOutput.connection(with: .video) {
            if connection.isVideoStabilizationSupported {
                connection.preferredVideoStabilizationMode = .auto
            }
        }

        self.movieOutput = movieOutput
    }

    private func addMetadataOutputToSession() throws {
        let metadataOutput = AVCaptureMetadataOutput()
        guard session.canAddOutput(metadataOutput) else {
            return
        }
        session.addOutput(metadataOutput)
        metadataOutput.setMetadataObjectsDelegate(metadataProcessor, queue: .main)
        metadataOutput.metadataObjectTypes = metadataProcessor.supportedObjectTypes
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
            try addMetadataOutputToSession()
            try addPhotoOutputToSession()
        } catch {
            printDebug(error)
            return
        }
        model.setupResult = .setupComplete

        printDebug("Starting session from initialSessionConfiguration")
        await start()
    }



}
