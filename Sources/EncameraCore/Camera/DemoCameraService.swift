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
    
    func stop() async {
        
    }
    
    func start() async {
        
    }
    
    func focus(at focusPoint: CGPoint) async {
        
    }
    
    func set(zoom: CGFloat) async {
        
    }
    
    func flipCameraDevice() async {
        
    }
    
    func configureForMode(targetMode: CameraMode) async {
        
    }

}
