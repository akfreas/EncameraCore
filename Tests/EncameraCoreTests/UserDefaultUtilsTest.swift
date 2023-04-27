//
//  UserDefaultUtilsTest.swift
//  EncameraTests
//
//  Created by Alexander Freas on 12.10.22.
//

import Foundation
import XCTest
import Combine
@testable import EncameraCore

class UserDefaultsUtilsTest: XCTestCase {
    
    private var cancellables = Set<AnyCancellable>()

    
    override func setUp() {
        UserDefaultUtils.removeAll()
        cancellables.forEach({$0.cancel()})
    }
    
    
    func testIncreaseIntegerWhenUnset() throws {
        UserDefaultUtils.increaseInteger(forKey: .capturedPhotos)
        UserDefaultUtils.increaseInteger(forKey: .capturedPhotos)
        let increased = UserDefaultUtils.value(forKey: .capturedPhotos) as! Int
        XCTAssertEqual(2, increased)
    }
    
    func testIncreaseInteger() throws {
        UserDefaultUtils.set(1, forKey: .capturedPhotos)
        UserDefaultUtils.increaseInteger(forKey: .capturedPhotos)
        let increased = UserDefaultUtils.value(forKey: .capturedPhotos) as! Int
        XCTAssertEqual(2, increased)
    }
    
    func testObserveIncrease() throws {
        let expect = expectation(description: "observe increase")
        expect.expectedFulfillmentCount = 2
        var expected = 1
        UserDefaultUtils.publisher(for: .capturedPhotos).sink { value in
            XCTAssertEqual(value as? Int, expected)
            expect.fulfill()
            expected += 1
        }.store(in: &cancellables)
        
        UserDefaultUtils.increaseInteger(forKey: .capturedPhotos)
        UserDefaultUtils.increaseInteger(forKey: .capturedPhotos)

        
        waitForExpectations(timeout: 5.0)
    }
    
}
