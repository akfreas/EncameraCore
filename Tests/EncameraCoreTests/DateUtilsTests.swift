//
//  DateUtilsTest.swift
//  EncameraTests
//
//  Created by Alexander Freas on 23.06.22.
//

import Foundation
@testable import EncameraCore
import XCTest

class DateUtilsTests: XCTestCase {
    
    func testDateToString() {
        
        let date = DateComponents(year: 2022, month: 2, day: 1)
        let string = DateUtils.dateOnlyString(from: Calendar(identifier: .gregorian).date(from: date)!)
        
        XCTAssertEqual(string, "2/1/22")
        
    }
}
