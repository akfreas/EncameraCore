//
//  CameraPermissionsService.swift
//
//
//  Created by Alexander Freas on 10.10.23.
//

import Foundation
import AVFoundation
import Combine

enum PermissionError: Error {
    case denied
    case restricted
    case notDetermined
    case unknown
}

public class CameraPermissionsService: ObservableObject {

    public static let shared = CameraPermissionsService()

    @Published private(set) public var isCameraAccessAuthorized: Bool = false
    @Published private(set) public var isMicrophoneAccessAuthorized: Bool = false

    private var cancellables: Set<AnyCancellable> = []

    private init() {
        // Initializing with current permission status
        isCameraAccessAuthorized = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        isMicrophoneAccessAuthorized = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    public func requestCameraPermission() async throws {
        let status = AVCaptureDevice.authorizationStatus(for: .video)

        switch status {
        case .authorized:
            isCameraAccessAuthorized = true
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            isCameraAccessAuthorized = granted
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
            isMicrophoneAccessAuthorized = true
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            isMicrophoneAccessAuthorized = granted
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
