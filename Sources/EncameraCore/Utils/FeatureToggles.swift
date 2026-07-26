//
//  FeatureToggles.swift
//  Encamera
//
//  Created by Alexander Freas on 28.10.22.
//

import Foundation

public enum Feature: String, CaseIterable {
    case debugTracking
    case enableTestRevenueCat
    case showFeatureToggles
    case encryptedZipExport
    case showDesignSystem
    case newPaywall
    case editRotation
    case detectDuplicates
    case megapixelSettings
    case clearMediaIndex
    case showDebugLogs

    var userDefaultsKey: String {
        return "feature_" +  rawValue
    }

    /// Cases shown in the feature toggles UI. The test RevenueCat key is a
    /// simulated-store key the SDK hard-asserts against in release builds, so
    /// that toggle only appears in DEBUG builds.
    public static var displayedCases: [Feature] {
        #if DEBUG
        return allCases
        #else
        return allCases.filter { $0 != .enableTestRevenueCat }
        #endif
    }

    public var title: String {
        switch self {
        case .debugTracking: return "Debug Tracking"
        case .enableTestRevenueCat: return L10n.FeatureToggles.enableTestRevenueCat
        case .showFeatureToggles: return L10n.FeatureToggles.showFeatureToggles
        case .encryptedZipExport: return L10n.FeatureToggles.encryptedZipExport
        case .showDesignSystem: return L10n.FeatureToggles.showDesignSystem
        case .newPaywall: return L10n.FeatureToggles.newPaywall
        case .editRotation: return L10n.FeatureToggles.editRotation
        case .detectDuplicates: return L10n.FeatureToggles.detectDuplicates
        case .megapixelSettings: return "Megapixel Settings"
        case .clearMediaIndex: return "Clear Media Index"
        case .showDebugLogs: return "Debug Logs"
        }
    }

    public var description: String {
        switch self {
        case .debugTracking: return "Intercept analytics events and display them in-app for debugging"
        case .enableTestRevenueCat: return L10n.FeatureToggles.enableTestRevenueCatDescription
        case .showFeatureToggles: return L10n.FeatureToggles.showFeatureTogglesDescription
        case .encryptedZipExport: return L10n.FeatureToggles.encryptedZipExportDescription
        case .showDesignSystem: return L10n.FeatureToggles.showDesignSystemDescription
        case .newPaywall: return L10n.FeatureToggles.newPaywallDescription
        case .editRotation: return L10n.FeatureToggles.editRotationDescription
        case .detectDuplicates: return L10n.FeatureToggles.detectDuplicatesDescription
        case .megapixelSettings: return "Allow selecting camera capture resolution (e.g. 12 MP, 48 MP)"
        case .clearMediaIndex: return "Show a debug action in Settings to delete the on-disk media index so its rebuild can be tested"
        case .showDebugLogs: return "Capture every printDebug line in memory and show a floating button that opens a viewer to search, copy, or share them"
        }
    }

    public var requiresConfirmation: Bool {
        switch self {
        case .debugTracking, .enableTestRevenueCat, .showDebugLogs:
            return true
        default:
            return false
        }
    }

    public var confirmationTitle: String? {
        switch self {
        case .debugTracking: return "Enable Debug Tracking"
        case .enableTestRevenueCat: return L10n.FeatureToggles.revenuecatToggleTitle
        case .showDebugLogs: return "Enable Debug Logs"
        default: return nil
        }
    }

    public var confirmationMessage: String? {
        switch self {
        case .debugTracking: return "Analytics events will be captured in-app instead of sent to services. Continue?"
        case .enableTestRevenueCat: return L10n.FeatureToggles.revenuecatToggleMessage
        case .showDebugLogs: return "Verbose internal log lines — including album names, file names and error details — will be held in memory until you disable this or quit the app, and can be copied or shared. Continue?"
        default: return nil
        }
    }
}

public struct FeatureToggle {

    /// Routed through `setEnabled` rather than writing UserDefaults directly, so
    /// `featureDidChange` stays a single choke point for in-memory mirrors.
    public static func enable(feature: Feature) {
        setEnabled(feature: feature, enabled: true)
    }

    public static func toggle(feature: Feature) {
        let currentValue = isEnabled(feature: feature)
        setEnabled(feature: feature, enabled: !currentValue)
    }

    public static func setEnabled(feature: Feature, enabled: Bool) {
        UserDefaultUtils.set(enabled, forKey: .featureToggle(feature: feature))
        featureDidChange(feature, enabled: enabled)
    }

    /// Mirrors toggles that are cached in memory, so hot paths never have to read
    /// UserDefaults.
    ///
    /// Every mutation funnels through `setEnabled` — the Feature Toggles screen,
    /// the `encamera://featureToggle` deep link, and the UI-test launch
    /// arguments all call it — so hooking here covers all of them at once.
    private static func featureDidChange(_ feature: Feature, enabled: Bool) {
        switch feature {
        case .showDebugLogs:
            // `printDebug` is on essentially every code path; it must not pay a
            // UserDefaults read per line.
            DebugLogBuffer.shared.setCapturing(enabled)
        default:
            break
        }
    }

    public static func isEnabled(feature: Feature) -> Bool {
        return UserDefaultUtils.bool(forKey: .featureToggle(feature: feature))
    }

}
