//
//  FeatureToggles.swift
//  Encamera
//
//  Created by Alexander Freas on 28.10.22.
//

import Foundation

public enum Feature: String {
    case enableVideo
    case stopTracking
    case recoveryPhrase
    var userDefaultsKey: String {
        return "feature_" +  rawValue
    }
}

public struct FeatureToggle {
    
    public static func enable(feature: Feature) {
        UserDefaultUtils.set(true, forKey: .featureToggle(feature: feature))
    }
    public static func isEnabled(feature: Feature) -> Bool {
        return UserDefaultUtils.bool(forKey: .featureToggle(feature: feature))
    }
    
}
