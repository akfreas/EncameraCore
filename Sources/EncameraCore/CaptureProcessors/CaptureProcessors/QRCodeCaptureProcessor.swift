//
//  QRCodeCaptureProcessor.swift
//  Encamera
//
//  Created by Alexander Freas on 22.11.21.
//

import Foundation
import AVFoundation
import Combine
import UIKit

class QRCodeCaptureProcessor: NSObject {
    var supportedObjectTypes: [AVMetadataObject.ObjectType] {
        return [.qr]
    }
    
    @Published var lastCaptured: String?
    
    
    private var cancellables = Set<AnyCancellable>()
}

extension QRCodeCaptureProcessor: AVCaptureMetadataOutputObjectsDelegate {
    
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        
        if let object = metadataObjects.first {
            guard let readableObject = object as? AVMetadataMachineReadableCodeObject,
                  let string = readableObject.stringValue,
                  lastCaptured != string else {
                return
            }
            lastCaptured = string
            guard let url = URL(string: string)
                else {
                return
            }
            cancellables.forEach({$0.cancel()})
            Just(false).delay(for: .seconds(2), scheduler: RunLoop.main).sink { value in
                print("clearing last captured")
                self.lastCaptured = nil
            }.store(in: &cancellables)
            UIApplication.shared.open(url)
        }
    }
    
}
