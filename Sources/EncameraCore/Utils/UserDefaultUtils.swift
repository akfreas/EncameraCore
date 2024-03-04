//
//  UserDefaultUtils.swift
//  Encamera
//
//  Created by Alexander Freas on 19.09.22.
//

import Foundation
import Combine

public struct UserDefaultUtils {

    #if DEBUG
    static var appGroup = "group.me.freas.encamera.debug"
    #else
    static var appGroup = "group.me.freas.encamera"
    #endif
    private static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroup) ?? UserDefaults.standard
    }
    
    private static var defaultsPublisher: AnyPublisher<(UserDefaultKey, Any?), Never> {
        defaultsSubject.eraseToAnyPublisher()
    }
    
    private static var defaultsSubject: PassthroughSubject = PassthroughSubject<(UserDefaultKey, Any?), Never>()
    
    public init() {}
    
    public static func increaseInteger(forKey key: UserDefaultKey) {
        var currentValue = value(forKey: key) as? Int ?? 0
        currentValue += 1
        set(currentValue, forKey: key)
        
    }
    
    public static func publisher(for observedKey: UserDefaultKey) -> AnyPublisher<Any?, Never> {
        return defaultsPublisher.filter { key, value in
            return observedKey == key
        }.map { key, value in
            return value
        }.share().eraseToAnyPublisher()
    }
    
    public static func integer(forKey key: UserDefaultKey) -> Int {
        return defaults.integer(forKey: key.rawValue)
    }
    
    public static func string(forKey key: UserDefaultKey) -> String? {
        return defaults.string(forKey: key.rawValue)
    }
    
    public static func set(_ value: Any?, forKey key: UserDefaultKey) {
        defaults.set(value, forKey: key.rawValue)
        defaultsSubject.send((key, value))
    }
    
    public static func value(forKey key: UserDefaultKey) -> Any? {
        return defaults.value(forKey: key.rawValue)
    }
    
    public static func bool(forKey key: UserDefaultKey) -> Bool {
        return defaults.bool(forKey: key.rawValue)
    }
    
    public static func removeObject(forKey key: UserDefaultKey) {
        return defaults.removeObject(forKey: key.rawValue)
    }

    public static func dictionary(forKey key: UserDefaultKey) -> [String: Any]? {
        return defaults.dictionary(forKey: key.rawValue)
    }

    public static func data(forKey key: UserDefaultKey) -> Data? {
        defaults.data(forKey: key.rawValue)
    }
    
    public static func removeAll() {
        defaults.dictionaryRepresentation().keys.forEach { key in
            defaults.removeObject(forKey: key)
        }
    }
    
    public static func migrateUserDefaultsToAppGroups() {
        
        // User Defaults - Old
        let userDefaults = UserDefaults.standard
        
        // App Groups Default - New
        let groupDefaults = UserDefaults(suiteName: appGroup)
        
        // Key to track if we migrated
        let didMigrateToAppGroups = "DidMigrateToAppGroups"
        
        if let groupDefaults = groupDefaults {
            if !groupDefaults.bool(forKey: didMigrateToAppGroups) {
                for (key, value) in userDefaults.dictionaryRepresentation() {
                    groupDefaults.set(value, forKey: key)
                }
                groupDefaults.set(true, forKey: didMigrateToAppGroups)
                groupDefaults.synchronize()
                print("Successfully migrated defaults")
            } else {
                print("No need to migrate defaults")
            }
        } else {
            print("Unable to create NSUserDefaults with given app group")
        }
        
    }
    
}
