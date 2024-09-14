//
//  URLTypesTest.swift
//  EncameraTests
//
//  Created by Alexander Freas on 08.09.22.
//

import Foundation
import XCTest
import Combine
@testable import EncameraCore


class URLTypesTest: XCTestCase {
    
    var key: PrivateKey!
    let keyManager = KeychainManager(isAuthenticated: Just(true).eraseToAnyPublisher())
    
    override func setUp() {
        
        key = try? keyManager.generateNewKey(name: NSUUID().uuidString)
    }
    
    override func tearDown() {
        keyManager.clearKeychainData()
    }
    
    
    func testConvertKeyType() throws {
    
        let url = try XCTUnwrap(URL(string: "encamera://key?data=eyJuYW1lIjoidGVzdCIsImtleUJ5dGVzIjpbMzYsOTcsMTE0LDEwMywxMTEsMTEwLDUwLDEwNSwxMDAsMzYsMTE4LDYxLDQ5LDU3LDM2LDEwOSw2MSw1NCw1Myw1Myw1MSw1NCw0NCwxMTYsNjEsNTAsNDQsMTEyLDYxLDQ5LDM2LDc2LDEyMiw3Myw0OCw3OCwxMDMsNjcsNTcsOTAsNjksODksNzYsODEsODAsNzAsNzYsODUsNDksNjksODAsMTE5LDY1LDM2LDgzLDY2LDY2LDQ5LDY1LDg1LDg2LDc0LDU1LDgyLDg1LDkwLDExNiw3OSw2NywxMTEsMTA0LDgyLDEwMCw4OSw2Nyw3MSw1NywxMTQsOTAsMTE5LDEwOSw4MSw0NywxMTgsNzQsNzcsMTIxLDQ4LDg1LDcxLDEwOCw2OSwxMDMsNjYsMTIyLDc5LDc3XSwiY3JlYXRpb25EYXRlIjo2NjYwNzIwMDB9"))
        let converted = URLType(url: url)
        XCTAssertEqual(converted, .key(key: DemoPrivateKey.dummyKey()))
        
        
    }
    
    func testFeatureToggleType() throws {
        let url = try XCTUnwrap(URL(string: "encamera://featureToggle?feature=enableVideo"))
        let converted = URLType(url: url)
        XCTAssertEqual(converted, .featureToggle(feature: .enableVideo))
    }
    
    func testConvertMediaLocationType() throws {
        
        let url = try XCTUnwrap(URL(string: "file:///private/var/mobile/Library/Mobile%20Documents/iCloud~Encamera/Documents/peaches/25280ADA-BEB5-4896-BFEF-ACC0D804653A.encimage"))
        
        let converted = URLType(url: url)
        
        XCTAssertEqual(converted, .media(encryptedMedia: EncryptedMedia(source: url)!))
    }
    
}
