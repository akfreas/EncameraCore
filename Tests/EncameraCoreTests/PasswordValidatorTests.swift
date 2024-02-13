//
//  PasswordValidatorTests.swift
//  EncameraTests
//
//  Created by Alexander Freas on 15.07.22.
//

import Foundation
import XCTest
@testable import EncameraCore

class PasswordValidatorTests: XCTestCase {
    
    private let validator = PasswordValidator()
    
    func testCheckPasswordValid() throws {
        let firstPassword = "q1w2e3r4"
        let secondPassword = "q1w2e3r4"
        
        let result = PasswordValidator.validatePasswordPair(firstPassword, password2: secondPassword)
        XCTAssertEqual(result, .valid)
    }
    
    func testCheckPasswordInvalidDifferent() throws {
        let firstPassword = "q1w2e3r4223"
        let secondPassword = "q1w2e3r4"
        
        let result = PasswordValidator.validatePasswordPair(firstPassword, password2: secondPassword)
        XCTAssertEqual(result, .invalidDifferent)
    }
    
    func testCheckPasswordInvalidTooLong() throws {
        let firstPassword = "1111111111111111111111111111111"
        let secondPassword = "1111111111111111111111111111111"
        
        let result = PasswordValidator.validatePasswordPair(firstPassword, password2: secondPassword)
        XCTAssertEqual(result, .invalidTooLong)
    }
    
    func testCheckPasswordInvalidTooShort() throws {
        let firstPassword = "123"
        let secondPassword = "123"
        let result = PasswordValidator.validatePasswordPair(firstPassword, password2: secondPassword)
        XCTAssertEqual(result, .invalidTooShort)

    }
    
}
