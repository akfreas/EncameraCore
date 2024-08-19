//
//  File.swift
//  
//
//  Created by Alexander Freas on 19.08.24.
//

import Foundation
import AVFoundation

public class CameraConfigurationServiceModel {
    @Published public var orientation: AVCaptureVideoOrientation = .portrait
    @Published public var cameraMode: CameraMode = .photo
    @Published public var canCaptureLivePhoto: Bool = true

    public var alertError: AlertError = AlertError()
    public var setupResult: SessionSetupResult = .notDetermined

    public init() {
    }
}
