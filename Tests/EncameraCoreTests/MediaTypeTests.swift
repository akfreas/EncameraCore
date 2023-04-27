//
//  MediaTypeTests.swift
//  EncameraTests
//
//  Created by Alexander Freas on 03.06.22.
//

import Foundation
import XCTest
@testable import EncameraCore

class MediaTypeTests: XCTestCase {
    
    func testEncryptedTypeDetermination() throws {
        
        let url = try XCTUnwrap(URL(string: "/Users/akfreas/Library/Developer/CoreSimulator/Devices/9D0BD392-4346-463B-883A-4F3B4B844374/data/Containers/Data/Application/3F9755A2-4CE1-4E6C-91F1-C7DE1B652C26/tmp/E78B48A6-503E-473F-832A-A0100979BCD1.encvideo"))
        
        let encrypted = try XCTUnwrap(EncryptedMedia(source: url))
                
        XCTAssertEqual(encrypted.mediaType, .video)
        
    }
    
    func testCleartextDataTypeDetermination() throws {
        let data = Data()
        
        let cleartext = CleartextMedia(source: data)
        
        XCTAssertEqual(cleartext.mediaType, .photo)
    }
    
    func testiCloudURLResolvesToCorrectMediaType() throws {
        let url = try XCTUnwrap(URL(string: "file:///private/var/mobile/Library/Mobile%20Documents/iCloud~Encamera/Documents/fitness/.50004CBC-D721-4DF9-9E19-ED04875023CF.encimage.icloud"))
        let encrypted = try XCTUnwrap(EncryptedMedia(source: url))
        XCTAssertEqual(encrypted.mediaType, .photo)
        
    }
    
    func testDownloadedSourceIsCorrect() throws {
        let url = try XCTUnwrap(URL(string: "file:///private/var/mobile/Library/Mobile%20Documents/iCloud~Encamera/Documents/fitness/.50004CBC-D721-4DF9-9E19-ED04875023CF.encimage.icloud"))
        let encrypted = try XCTUnwrap(EncryptedMedia(source: url))

        XCTAssertEqual(encrypted.downloadedSource, URL(string:"file:///private/var/mobile/Library/Mobile%20Documents/iCloud~Encamera/Documents/fitness/50004CBC-D721-4DF9-9E19-ED04875023CF.encimage"))
    }
    
}
