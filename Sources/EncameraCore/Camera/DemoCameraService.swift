//
//  DemoCameraService.swift
//  Encamera
//
//  Created by Alexander Freas on 27.06.22.
//

import Foundation
import AVFoundation
import Combine


class DemoCameraService: CameraConfigurationServicable {
    func set(zoom: ZoomLevel) async {

    }
    @discardableResult
    func setContinuousZoom(factor: CGFloat) async -> CGFloat {
        return 1.0
    }
    func currentVideoZoomFactor() async -> CGFloat {
        return 1.0
    }
    func nearestAvailableZoomLevel(forVideoZoomFactor factor: CGFloat) async -> ZoomLevel? {
        return .x1
    }
    func set(rotationAngle: CGFloat) async {

    }
    func setDelegate(_ delegate: CameraConfigurationServicableDelegate) async {
        
    }
    
    var session: AVCaptureSession
    
    var model: CameraConfigurationServiceModel
    
    required init(model: CameraConfigurationServiceModel) {
        self.model = .init()
        self.session = AVCaptureSession()
    }
    
    func configure() async {
        
    }
    
    func checkForPermissions() async {
        
    }
    
    func stop(observeRestart: Bool) async {
    
    }
    
    func start() async {
        
    }
    
    func focus(at focusPoint: CGPoint) async {

    }

    func setExposureTargetBias(_ bias: Float) async {

    }

    func resetExposureTargetBias() async {

    }
    
    func set(zoom: CGFloat) async {
        
    }
    
    func flipCameraDevice() async {
        
    }
    
    func configureForMode(targetMode: CameraMode, videoQuality: VideoQualityOption?, force: Bool) async {

    }

}
