//
//  URL.swift
//  Encamera
//
//  Created by Alexander Freas on 27.10.22.
//

import Foundation

extension URL {
    
    public static var tempMediaDirectory: URL {
        URL(fileURLWithPath: NSTemporaryDirectory().appending("decrypted"),
                                    isDirectory: true)
    }


    public static var tempRecordingDirectory: URL {
        URL(fileURLWithPath: NSTemporaryDirectory().appending("recordings"),
                                    isDirectory: true)
    }

    public static var tempExportDirectory: URL {
        URL(fileURLWithPath: NSTemporaryDirectory().appending("exports"),
                                    isDirectory: true)
    }

    public func fileSizeBytes() -> Int64? {
        guard let size = (try? resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { return nil }
        return Int64(size)
    }

}
