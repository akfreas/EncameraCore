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

public protocol CameraConfigurationServicableDelegate {
    func didUpdate(zoomLevels: [ZoomLevel])
}

protocol CameraConfigurationServicable {
    var session: AVCaptureSession { get }
    var model: CameraConfigurationServiceModel { get }
    init(model: CameraConfigurationServiceModel)
    func configure() async
    func checkForPermissions() async
    func stop() async
    func start() async
    func focus(at focusPoint: CGPoint) async
    func set(zoom: ZoomLevel) async
    func flipCameraDevice() async
    func configureForMode(targetMode: CameraMode) async
    func setDelegate(_ delegate: CameraConfigurationServicableDelegate) async
}


public class CameraConfigurationServiceModel {
    @Published public var orientation: AVCaptureVideoOrientation = .portrait
    @Published public var cameraMode: CameraMode = .photo

    public var alertError: AlertError = AlertError()
    public var setupResult: SessionSetupResult = .notDetermined

    public init() {
    }
}
public enum ZoomLevel: CGFloat {
    case x05 = 0.5
    case x1 = 1.0
    case x2 = 2.0
    case x3 = 3.0
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

public actor CameraConfigurationService: CameraConfigurationServicable {

    public var currentCameraDeviceType: AVCaptureDevice.DeviceType?
    public var currentCameraPosition: AVCaptureDevice.Position?

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
    private let videoDeviceDiscoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .builtInDualCamera, .builtInTrueDepthCamera], mediaType: .video, position: .unspecified)
    private var cancellables = Set<AnyCancellable>()
    
    public init(model: CameraConfigurationServiceModel) {
        self.model = model
    }
    
    public func configure() async {
        if model.setupResult == .setupComplete {
            await start()
        } else {
            await self.initialSessionConfiguration()
        }
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
    
    
    public func stop() async {
        guard self.session.isRunning, self.model.setupResult == .setupComplete else {
            debugPrint("Could not stop session, isSessionRunning: \(self.session.isRunning), model.setupResult: \(model.setupResult)")
            return
        }
        cancellables.forEach({ $0.cancel() })
        cancellables.removeAll()
        self.session.stopRunning()
    }
    
    func start() async {
        guard !self.session.isRunning else {
            debugPrint("Session is running already or is not configured")
            return
        }
        switch self.model.setupResult {
        case .setupComplete:
            self.session.startRunning()
            NotificationUtils.didEnterBackgroundPublisher
                .sink { _ in
                    Task {
                        await self.stop()
                    }
                }.store(in: &cancellables)
            NotificationUtils.willResignActivePublisher
                .sink { _ in
                    Task {
                        await self.stop()
                    }

                }.store(in: &cancellables)
            guard self.session.isRunning else {
                debugPrint("Session is not running")
                return
            }
        default:
            fatalError()
        }
    }
    
    func focus(at focusPoint: CGPoint) async {
        guard let device = self.videoDeviceInput?.device else {
            debugPrint("Trying to focus, video device is nil")
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
            debugPrint(error.localizedDescription)
        }
    }


    func loadAvailableZoomFactors() async {
        let discoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .builtInTelephotoCamera, .builtInUltraWideCamera], mediaType: .video, position: .back)

        for camera in discoverySession.devices {
            switch camera.deviceType {
            case .builtInUltraWideCamera:
                zoomLevels[.x05] = ZoomControlModel(zoomLevel: .x05, captureDevice: camera, useDigitalZoom: false)
            case .builtInWideAngleCamera:
                zoomLevels[.x1] = ZoomControlModel(zoomLevel: .x1, captureDevice: camera, useDigitalZoom: false)
                zoomLevels[.x2] = ZoomControlModel(zoomLevel: .x2, captureDevice: camera, useDigitalZoom: true)
            case .builtInTelephotoCamera:
                zoomLevels[.x3] = ZoomControlModel(zoomLevel: .x3, captureDevice: camera, useDigitalZoom: false)
            default:
                break
            }
        }
    }

    public func set(zoom: ZoomLevel) async {
        // Find the camera device for the given zoom level.
        guard let zoomLevel = zoomLevels[zoom], let newCamera = zoomLevel.captureDevice else {
            debugPrint("No camera available for the given zoom level: \(zoom)")
            return
        }

        // Check if the selected camera is different from the current one.
        if newCamera != self.videoDeviceInput?.device {
            do {
                let newVideoDeviceInput = try AVCaptureDeviceInput(device: newCamera)

                // Remove the current video device input from the session.
                if let videoDeviceInput = self.videoDeviceInput {
                    self.session.removeInput(videoDeviceInput)
                }

                // Add the new video device input to the session.
                if self.session.canAddInput(newVideoDeviceInput) {
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
                debugPrint("Error occurred while switching video device input: \(error)")
                return
            }
        }
        if zoomLevel.useDigitalZoom {
            // Set the capture device's zoom factor.
            do {
                try newCamera.lockForConfiguration()
                newCamera.videoZoomFactor = CGFloat(zoomLevel.zoomLevel.rawValue)
                newCamera.unlockForConfiguration()
            } catch {
                debugPrint("Error occurred while setting video zoom factor: \(error)")
                return
            }
        } else {
            // Reset the capture device's zoom factor.
            do {
                try newCamera.lockForConfiguration()
                newCamera.videoZoomFactor = 1.0
                newCamera.unlockForConfiguration()
            } catch {
                debugPrint("Error occurred while setting video zoom factor: \(error)")
                return
            }
        }
    }

    public func flipCameraDevice() async {
        
        guard let currentVideoDevice = self.videoDeviceInput?.device else {
            debugPrint("Current video device is nil")
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
            debugPrint("Unknown capture position. Defaulting to back, dual-camera.")
            preferredPosition = .back
            preferredDeviceType = .builtInWideAngleCamera
        }
        let devices = self.videoDeviceDiscoverySession.devices
        var newVideoDevice: AVCaptureDevice? = nil
        
        // First, seek a device with both the preferred position and device type. Otherwise, seek a device with only the preferred position.
        if let device = devices.first(where: { $0.position == preferredPosition && $0.deviceType == preferredDeviceType }) {
            newVideoDevice = device
        } else if let device = devices.first(where: { $0.position == preferredPosition }) {
            newVideoDevice = device
        }
        
        guard let videoDevice = newVideoDevice else {
            debugPrint("New video device is nil")
            return
        }

        currentCameraDeviceType = preferredDeviceType
        currentCameraPosition = preferredPosition

        do {
            let newVideoDeviceInput = try AVCaptureDeviceInput(device: videoDevice)
            
            
            if let videoDeviceInput = self.videoDeviceInput {
                self.session.removeInput(videoDeviceInput)
            }
            
            if self.session.canAddInput(newVideoDeviceInput) {
                self.session.addInput(newVideoDeviceInput)
                self.videoDeviceInput = newVideoDeviceInput
                
            } else if let videoDeviceInput = self.videoDeviceInput {
                self.session.addInput(videoDeviceInput)
            }
            
            if let connection = self.photoOutput.connection(with: .video) {
                if connection.isVideoStabilizationSupported {
                    connection.preferredVideoStabilizationMode = .auto
                }
            }
        } catch {
            debugPrint("Error occurred while creating video device input: \(error)")
        }
        await loadAvailableZoomFactors()
    }
    
    public func configureForMode(targetMode: CameraMode) async {
        session.beginConfiguration()
        defer {
            session.commitConfiguration()
        }
        do {
            switch targetMode {
            case .photo:
                try self.addPhotoOutputToSession()
            case .video:
                try self.addVideoOutputToSession()
            }
            
        } catch {
            debugPrint("Could not switch to mode \(targetMode)", error)
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
    
    
    public func createPhotoProcessor(flashMode: AVCaptureDevice.FlashMode) async throws -> AsyncPhotoCaptureProcessor {
        guard self.model.setupResult != .configurationFailed else {
            debugPrint("Could not capture photo")
            throw MediaProcessorError.setupIncomplete
        }
        
        if let photoOutputConnection = self.photoOutput.connection(with: .video) {
            photoOutputConnection.videoOrientation = model.orientation
        }
        var photoSettings = AVCapturePhotoSettings()
        // Capture HEIF photos when supported. Enable according to user settings and high-resolution photos.
        if photoOutput.availablePhotoCodecTypes.contains(.hevc) {
            photoSettings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
        }
        
        // Sets the flash option for this capture.
        if let videoDeviceInput = self.videoDeviceInput,
           videoDeviceInput.device.isFlashAvailable {
            photoSettings.flashMode = flashMode
        }
        
        photoSettings.isHighResolutionPhotoEnabled = true
        
        return AsyncPhotoCaptureProcessor(output: photoOutput, requestedPhotoSettings: photoSettings)
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
                debugPrint("Torch could not be used")
            }
        } else {
            debugPrint("Torch is not available")
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
        
        guard session.canAddOutput(photoOutput) else {
            debugPrint("Could not add photooutput to session")
            return
        }
        debugPrint("Calling addPhotoOutputToSession")
        
        session.addOutput(photoOutput)
    }
    
    private func addVideoOutputToSession() throws {
        debugPrint("Calling addVideoOutputToSession")
        
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
    
    private func setupVideoCaptureDevice() throws {
        session.sessionPreset = .photo
        
        var defaultVideoDevice: AVCaptureDevice?
        let cameraTypes: [AVCaptureDevice.DeviceType] = [
            .builtInDualCamera,
            .builtInWideAngleCamera,
            .builtInDualWideCamera,
            .builtInTelephotoCamera,
            .builtInUltraWideCamera
        ]

        // Try to find a suitable camera among the types
        for cameraType in cameraTypes {
            if let device = AVCaptureDevice.default(cameraType, for: .video, position: .back) {
                defaultVideoDevice = device
                currentCameraDeviceType = cameraType
                currentCameraPosition = .back
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
                debugPrint("Could not add input to session")
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
            debugPrint(error)
            return
        }
        model.setupResult = .setupComplete
        
        await start()
        await loadAvailableZoomFactors()
    }
    
    
    
}
