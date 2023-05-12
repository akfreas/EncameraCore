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


protocol CameraConfigurationServicable {
    var session: AVCaptureSession { get }
    var model: CameraConfigurationServiceModel { get }
    init(model: CameraConfigurationServiceModel)
    func configure() async
    func checkForPermissions() async
    func stop() async
    func start() async
    func focus(at focusPoint: CGPoint) async
    func set(zoom: CGFloat) async
    func changeCamera() async
    func configureForMode(targetMode: CameraMode) async
}


public class CameraConfigurationServiceModel {
    public var alertError: AlertError = AlertError()
    @Published public var cameraMode: CameraMode = .photo
    public var setupResult: SessionSetupResult = .notDetermined
    @Published public var orientation: AVCaptureVideoOrientation = .portrait
    
    public init() {
        
    }
}

public actor CameraConfigurationService: CameraConfigurationServicable {
    
    nonisolated public let session = AVCaptureSession()
    public let model: CameraConfigurationServiceModel
    
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
    
    
    func stop() async {
        guard self.session.isRunning, self.model.setupResult == .authorized else {
            debugPrint("Could not stop session, isSessionRunning: \(self.session.isRunning), model.setupResult: \(model.setupResult)")
            return
        }
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
    
    
    public func set(zoom: CGFloat) async {
        guard let device = videoDeviceInput?.device else {
            debugPrint("Could not get device for zooming")
            return
        }
        let factor = zoom < 1 ? 1 : zoom
        
        do {
            try device.lockForConfiguration()
            let clampedZoomFactor = min(factor, device.activeFormat.videoMaxZoomFactor)
            device.videoZoomFactor = clampedZoomFactor
            device.unlockForConfiguration()
        }
        catch {
            debugPrint(error.localizedDescription)
        }
    }
    
    public func changeCamera() async {
        
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
        
        if let dualCameraDevice = AVCaptureDevice.default(.builtInDualCamera, for: .video, position: .back) {
            defaultVideoDevice = dualCameraDevice
        } else if let dualWideCameraDevice = AVCaptureDevice.default(.builtInDualWideCamera, for: .video, position: .back) {
            // If a rear dual camera is not available, default to the rear dual wide camera.
            defaultVideoDevice = dualWideCameraDevice
        } else if let backCameraDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) {
            // If a rear dual wide camera is not available, default to the rear wide angle camera.
            defaultVideoDevice = backCameraDevice
        } else if let frontCameraDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) {
            // If the rear wide angle camera isn't available, default to the front wide angle camera.
            defaultVideoDevice = frontCameraDevice
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
        
        await self.start()
    }
    
    
    
}
