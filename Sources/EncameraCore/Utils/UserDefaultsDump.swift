//
//  UserDefaultsDump.swift
//  Encamera
//
//  Debug UserDefaults inspector support. Dumps every key the app has stored in
//  both the app-group UserDefaults and NSUbiquitousKeyValueStore, filtering out
//  system-owned entries.
//

import Foundation

public struct UserDefaultsDumpAttribute: Identifiable {
    public let id = UUID()
    public let label: String
    public let value: String
}

public struct UserDefaultsDumpEntry: Identifiable {
    public let id = UUID()
    public let key: String
    public let valueType: String
    public let displayValue: String
    public let isInLocalDefaults: Bool
    public let isInCloudStore: Bool
    public let attributes: [UserDefaultsDumpAttribute]
}

extension UserDefaultUtils {

    public static func dumpAllUserDefaultEntries() -> [UserDefaultsDumpEntry] {
        let localDefaults = UserDefaults(suiteName: appGroup) ?? UserDefaults.standard
        let localDict = localDefaults.dictionaryRepresentation()
        let cloud = NSUbiquitousKeyValueStore.default
        let cloudDict = cloud.dictionaryRepresentation

        var allKeys = Set<String>()
        allKeys.formUnion(localDict.keys)
        allKeys.formUnion(cloudDict.keys)

        let filtered = allKeys.filter { key in
            !systemOwnedDefaultsPrefixes.contains { key.hasPrefix($0) }
        }

        return filtered.sorted().map { key in
            let localValue = localDict[key]
            let cloudValue = cloudDict[key]
            let isLocal = localValue != nil
            let isCloud = cloudValue != nil

            let displayVal = cloudValue ?? localValue
            let typeStr = describeDefaultsType(of: displayVal)
            let displayStr = describeDefaultsValue(displayVal)

            var attrs: [UserDefaultsDumpAttribute] = []
            attrs.append(.init(label: "Key", value: key))
            attrs.append(.init(label: "Type", value: typeStr))
            if isLocal {
                attrs.append(.init(label: "Local Value", value: describeDefaultsValue(localValue)))
            }
            if isCloud {
                attrs.append(.init(label: "Cloud Value", value: describeDefaultsValue(cloudValue)))
            }
            if isLocal && isCloud {
                let match = describeDefaultsValue(localValue) == describeDefaultsValue(cloudValue)
                attrs.append(.init(label: "Local/Cloud Match", value: match ? "Yes" : "No"))
            }
            attrs.append(.init(label: "In Local Defaults", value: isLocal ? "Yes" : "No"))
            attrs.append(.init(label: "In iCloud KVS", value: isCloud ? "Yes" : "No"))

            return UserDefaultsDumpEntry(
                key: key,
                valueType: typeStr,
                displayValue: displayStr,
                isInLocalDefaults: isLocal,
                isInCloudStore: isCloud,
                attributes: attrs
            )
        }
    }

    private static func describeDefaultsType(of value: Any?) -> String {
        guard let value else { return "nil" }
        if let number = value as? NSNumber {
            return CFGetTypeID(number) == CFBooleanGetTypeID() ? "Bool" : "Number"
        }
        switch value {
        case is String: return "String"
        case is Data: return "Data"
        case is [String: Any]: return "Dictionary"
        case is [Any]: return "Array"
        case is Date: return "Date"
        default: return String(describing: type(of: value))
        }
    }

    private static func describeDefaultsValue(_ value: Any?) -> String {
        guard let value else { return "(nil)" }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            return "\(number)"
        }
        switch value {
        case let string as String:
            return string
        case let data as Data:
            if let string = String(data: data, encoding: .utf8), !string.isEmpty,
               string.unicodeScalars.allSatisfy({ !$0.properties.isDefaultIgnorableCodePoint }) {
                return "\(string)  (\(data.count) bytes)"
            }
            let hexPreview = data.prefix(32).map { String(format: "%02x", $0) }.joined()
            let ellipsis = data.count > 32 ? "…" : ""
            return "0x\(hexPreview)\(ellipsis)  (\(data.count) bytes)"
        case let dict as [String: Any]:
            let keys = dict.keys.sorted().joined(separator: ", ")
            return "{\(dict.count) key\(dict.count == 1 ? "" : "s"): \(keys)}"
        case let array as [Any]:
            return "[\(array.count) item\(array.count == 1 ? "" : "s")]"
        case let date as Date:
            return "\(date)"
        default:
            return String(describing: value)
        }
    }
}
