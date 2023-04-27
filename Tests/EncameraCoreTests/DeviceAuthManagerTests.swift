//
//  DeviceAuthManagerTests.swift
//  EncameraTests
//
//  Created by Alexander Freas on 05.09.22.
//

import Foundation
import XCTest
@testable import EncameraCore

class DeviceAuthManagerTests: XCTestCase {
    
    private var authManager: DeviceAuthManager!
    
    override func setUp() {
        authManager = DeviceAuthManager(settingsManager: SettingsManager())
    }
    
    
    func testWaitForAuthResponseUnauthed() async throws {
        
        let result = await authManager.waitForAuthResponse(delay: 3)
        XCTAssertEqual(result, .unauthenticated)
    }
    func testWaitForAuthResponseAuthed() async throws {
        
        let keyManager = DemoKeyManager()
        keyManager.password = "1234"
        Task {
            sleep(1)
            try authManager.authorize(with: "1234", using: keyManager)
        }
        let result = await authManager.waitForAuthResponse(delay: 3)

        XCTAssertEqual(result, .authenticated(with: .password))
    }
}
