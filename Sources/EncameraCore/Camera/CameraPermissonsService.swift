//
//  CameraPermissionsService.swift
//
//
//  Created by Alexander Freas on 10.10.23.
//

import Foundation
import AVFoundation
import Combine

public enum PermissionError: Error {
    case denied
    case restricted
    case notDetermined
    case unknown
}

public class CameraPermissionsService: ObservableObject {

    public static let shared = CameraPermissionsService()

    @MainActor
    @Published private(set) public var isCameraAccessAuthorized: Bool = false
    @MainActor
    @Published private(set) public var isMicrophoneAccessAuthorized: Bool = false

    private var cancellables: Set<AnyCancellable> = []

    private init() {
        // Initializing with current permission status
        Task { @MainActor in
            isCameraAccessAuthorized = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
            isMicrophoneAccessAuthorized = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        }
    }

    public func requestCameraPermission() async throws {
        let status = AVCaptureDevice.authorizationStatus(for: .video)

        switch status {
        case .authorized:

            Task { @MainActor in
                isCameraAccessAuthorized = true
            }
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            Task { @MainActor in
                isCameraAccessAuthorized = granted
            }
            if !granted {
                throw PermissionError.denied
            }
        default:
            throw PermissionError.denied
        }
    }

    public func requestMicrophonePermission() async throws {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)

        switch status {
        case .authorized:
            Task { @MainActor in
                isMicrophoneAccessAuthorized = true
            }
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            Task { @MainActor in
                isMicrophoneAccessAuthorized = granted
            }
            if !granted {
                throw PermissionError.denied
            }
        default:
            throw PermissionError.denied
        }
    }

    var cameraAccessPublisher: AnyPublisher<Bool, Never> {
        $isCameraAccessAuthorized
            .dropFirst()
            .eraseToAnyPublisher()
    }

    var microphoneAccessPublisher: AnyPublisher<Bool, Never> {
        $isMicrophoneAccessAuthorized
            .dropFirst()
            .eraseToAnyPublisher()
    }
}
