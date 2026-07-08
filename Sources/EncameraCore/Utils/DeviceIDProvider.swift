//
//  DeviceIDProvider.swift
//  EncameraCore
//
//  A stable, device-local identifier. Unlike the analytics visitor ID, this
//  identity must never leave the device: it is stored ThisDeviceOnly and never
//  synchronized, so it survives reinstalls but does NOT migrate to a new phone
//  (backup restore / Quick Start). An upgraded device therefore mints a fresh
//  identity instead of duplicating the old one — device identity is only ever
//  informational UX metadata ("backup was turned off from Alex's iPhone"),
//  never authorization.
//

import Foundation
import Security
#if canImport(UIKit)
import UIKit
#endif

public final class DeviceIDProvider: Sendable {

    static let account = "device_id"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cachedID: String?
    /// Injectable for tests — the bare xctest runner has no keychain entitlement,
    /// so unit tests swap in an in-memory implementation.
    nonisolated(unsafe) static var storage: DeviceIDStorage = KeychainDeviceIDStorage()

    /// Retrieves the existing device ID from the Keychain, or mints and stores
    /// a new one.
    public static func deviceID() -> String {
        lock.lock()
        defer { lock.unlock() }

        if let cached = cachedID {
            return cached
        }
        if let existing = storage.load(account: account) {
            cachedID = existing
            return existing
        }
        let newID = UUID().uuidString.lowercased()
        storage.save(newID, account: account)
        cachedID = newID
        return newID
    }

    /// A user-recognizable name for this device. Without the
    /// user-assigned-device-name entitlement this is the generic model name
    /// ("iPhone") on iOS 16+ — still useful as "another device" context.
    public static func deviceName() -> String {
        #if canImport(UIKit)
        return UIDevice.current.name
        #else
        return Host.current().localizedName ?? "Mac"
        #endif
    }

    /// Clears the process-lifetime cache WITHOUT touching storage. Lets tests
    /// simulate an app relaunch against persisted keychain state.
    static func clearProcessStateForTesting() {
        lock.lock()
        defer { lock.unlock() }
        cachedID = nil
    }
}

// MARK: - Storage

protocol DeviceIDStorage {
    func save(_ value: String, account: String)
    func load(account: String) -> String?
    func delete(account: String)
}

struct KeychainDeviceIDStorage: DeviceIDStorage {

    private static let service = "com.encamera.device"

    func save(_ value: String, account: String) {
        guard let data = value.data(using: .utf8) else { return }

        delete(account: account)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            // ThisDeviceOnly: never migrates to another device via backup
            // restore or device transfer, and can never be marked synchronizable.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable as String: false
        ]

        SecItemAdd(query as CFDictionary, nil)
    }

    func load(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
    }

    func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false
        ]
        SecItemDelete(query as CFDictionary)
    }
}
