//
//  DateUtils.swift
//  EncameraTests
//
//  Created by Alexander Freas on 23.06.22.
//

import Foundation


public class DateUtils {
    
    private static var dateOnlyFormatter: DateFormatter = {
       let formatter = DateFormatter()
        formatter.dateFormat = "YYYY.MM.dd"
        return formatter
    }()
    
    private static var dateTimeFormatter: DateFormatter = {
       let formatter = DateFormatter()
        formatter.dateFormat = "YYYY.MM.dd HH:MM:SS"
        return formatter
    }()
    
    public static func dateOnlyString(from date: Date) -> String {
        DateFormatter.localizedString(from: date, dateStyle: .short, timeStyle: .none)
    }
    
    public static func dateTimeString(from date: Date) -> String {
        DateFormatter.localizedString(from: date, dateStyle: .long, timeStyle: .long)
    }
}
