//
//  StoreKitUtils.swift
//  Encamera
//
//  Created by Alexander Freas on 12.10.22.
//

import Foundation
import StoreKit

enum RenewalFrequency: String {
    case monthly
    case yearly
    
}

public enum AppFeature {
    case accessPhoto(count: Double)
    case createKey(count: Double)
}
