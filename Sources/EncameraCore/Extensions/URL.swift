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

}
