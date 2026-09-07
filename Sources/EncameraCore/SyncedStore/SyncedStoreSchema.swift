//
//  SyncedStoreSchema.swift
//  EncameraCore
//
//  Created for iCloud synced data store feature.
//

import Foundation

// MARK: - Field Types

/// Represents the data type of a synced field
public enum SyncedFieldType {
    case string
    case int
    case double
    case date
    case bool
}

// MARK: - Field Definition

/// Represents a single field in a synced table schema
public struct SyncedField {
    /// The name of the field (used as dictionary key in storage)
    public let name: String
    
    /// The data type of the field
    public let type: SyncedFieldType
    
    /// Whether this field should be encrypted before storage
    public let isEncrypted: Bool
    
    public init(name: String, type: SyncedFieldType, isEncrypted: Bool) {
        self.name = name
        self.type = type
        self.isEncrypted = isEncrypted
    }
}

// MARK: - Table Schema

/// Represents the schema for a synced data table
public struct SyncedTableSchema {
    /// The name of the table (used to generate storage keys)
    public let tableName: String
    
    /// The name of the field that serves as the primary key
    public let primaryKey: String
    
    /// All fields in the schema
    public let fields: [SyncedField]
    
    /// The storage key used in UserDefaults and NSUbiquitousKeyValueStore
    public var storageKey: String {
        "synced_store_\(tableName)"
    }
    
    /// Fields that require encryption
    public var encryptedFields: [SyncedField] {
        fields.filter { $0.isEncrypted }
    }
    
    /// Fields that do not require encryption
    public var unencryptedFields: [SyncedField] {
        fields.filter { !$0.isEncrypted }
    }
    
    /// Whether the primary key field should be encrypted/hashed for storage
    public var isPrimaryKeyEncrypted: Bool {
        field(named: primaryKey)?.isEncrypted ?? false
    }
    
    /// Get a field by name
    public func field(named name: String) -> SyncedField? {
        fields.first { $0.name == name }
    }
    
    /// Check if a field with the given name should be encrypted
    public func isFieldEncrypted(_ fieldName: String) -> Bool {
        field(named: fieldName)?.isEncrypted ?? false
    }
    
    public init(tableName: String, primaryKey: String, fields: [SyncedField]) {
        self.tableName = tableName
        self.primaryKey = primaryKey
        self.fields = fields
    }
}

// MARK: - Schema Registry

/// Registry of all synced data table schemas
public enum SyncedStoreSchemas {
    
    /// Schema for storing album metadata and settings
    /// - album_name: The name of the album (encrypted in record, hashed for storage key)
    /// - date_added: When the album was added to the synced store
    /// - is_hidden: Whether the album is hidden from the main album list
    /// Note: Since album_name is marked encrypted and is the primary key,
    /// it will be hashed when used as a dictionary key in storage for privacy.
    public static let albums = SyncedTableSchema(
        tableName: "albums",
        primaryKey: "album_name",
        fields: [
            SyncedField(name: "album_name", type: .string, isEncrypted: true),
            SyncedField(name: "date_added", type: .date, isEncrypted: false),
            SyncedField(name: "is_hidden", type: .bool, isEncrypted: false),
            SyncedField(name: "cover_image_id", type: .string, isEncrypted: false)
        ]
    )
}

// MARK: - Schema Validation

extension SyncedTableSchema {
    
    /// Validates that a record dictionary conforms to this schema
    /// - Parameter record: The record to validate
    /// - Returns: True if the record contains the primary key field
    public func validateRecord(_ record: [String: Any]) -> Bool {
        // Must have primary key
        guard record[primaryKey] != nil else {
            return false
        }
        return true
    }
    
    /// Extracts the primary key value from a record
    /// - Parameter record: The record dictionary
    /// - Returns: The primary key value as a string, or nil if not found
    public func primaryKeyValue(from record: [String: Any]) -> String? {
        if let stringValue = record[primaryKey] as? String {
            return stringValue
        }
        return nil
    }
}
