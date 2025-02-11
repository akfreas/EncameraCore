//
//  CaptureProcessor.swift
//  Encamera
//
//  Created by Alexander Freas on 02.06.22.
//

import Foundation
import AVFoundation

protocol CaptureProcessor {
    init(
        completionHandler: @escaping (CaptureProcessor) -> Void,
        photoProcessingHandler: @escaping (Bool) -> Void,
        fileWriter: FileWriter)
}
