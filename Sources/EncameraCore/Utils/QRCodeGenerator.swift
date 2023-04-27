//
//  QRCodeGenerator.swift
//  Encamera
//
//  Created by Alexander Freas on 07.09.22.
//

import Foundation
import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins

public class QRCodeGenerator {
    
    public static func generateQRCode(from string: String, size: CGSize) -> UIImage {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        
        let data = Data(string.utf8)
        filter.setValue(data, forKey: "inputMessage")
        guard let output = filter.outputImage else {
            fatalError("no image")
        }
        let x = size.width / output.extent.size.width
        let y = size.height / output.extent.size.height
        
        let qrCodeImage = output.transformed(by: CGAffineTransform(scaleX: x, y: y))
        
        if let qrCodeCGImage = context.createCGImage(qrCodeImage, from: qrCodeImage.extent) {
            return UIImage(cgImage: qrCodeCGImage)
        }
        
        return UIImage(systemName: "xmark") ?? UIImage()
    }
}
