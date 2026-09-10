//
//  CloudKitContainer.swift
//  EncameraCore
//
//  Provisioning-only accessor for the Encamera CloudKit container: account-status
//  gating and idempotent custom-zone creation. Performs NO media I/O — that is
//  chunk 02. See plans/cloudkit-migration/01-cloudkit-foundations.md.
//

import Foundation
import CloudKit

// MARK: - Injectable seams (so tests never touch a live iCloud account)

/// Supplies the CloudKit account status. Backed by `CKContainer` in production,
/// stubbed in tests.
public protocol AccountStatusProviding {
    func currentAccountStatus() async throws -> CKAccountStatus
}

extension CKContainer: AccountStatusProviding {
    public func currentAccountStatus() async throws -> CKAccountStatus {
        try await accountStatus()
    }
}

/// Creates a custom record zone. Backed by `CKDatabase` in production, mocked in
/// tests so the idempotency contract can be verified offline.
public protocol RecordZoneProvisioning {
    func saveZone(_ zone: CKRecordZone) async throws
    func deleteZone(_ zoneID: CKRecordZone.ID) async throws
}

extension CKDatabase: RecordZoneProvisioning {
    public func saveZone(_ zone: CKRecordZone) async throws {
        _ = try await modifyRecordZones(saving: [zone], deleting: [])
    }

    public func deleteZone(_ zoneID: CKRecordZone.ID) async throws {
        _ = try await modifyRecordZones(saving: [], deleting: [zoneID])
    }
}

/// Lists the record zones that exist in the database. Only the erase needs
/// this, so it is a seam of its own rather than part of `RecordZoneProvisioning`.
public protocol RecordZoneListing {
    func existingZoneIDs() async throws -> [CKRecordZone.ID]
}

extension CKDatabase: RecordZoneListing {
    public func existingZoneIDs() async throws -> [CKRecordZone.ID] {
        try await allRecordZones().map(\.zoneID)
    }
}

/// Lists and deletes the database's subscriptions. The zone subscription the
/// media store registers is a record of its own and is not removed with the zone.
public protocol SubscriptionProvisioning {
    func allSubscriptionIDs() async throws -> [String]
    func deleteSubscription(id: String) async throws
}

extension CKDatabase: SubscriptionProvisioning {
    public func allSubscriptionIDs() async throws -> [String] {
        try await allSubscriptions().map(\.subscriptionID)
    }

    public func deleteSubscription(id: String) async throws {
        _ = try await deleteSubscription(withID: id)
    }
}

// MARK: - Container

/// Thin, defensive accessor for the app's CloudKit private database.
///
/// Mirrors the posture of `DataStorageAvailabilityUtil.isStorageTypeAvailable`
/// (which checks `ubiquityIdentityToken`): if there is no usable iCloud account,
/// CloudKit is reported unavailable and the app stays on local-only. We never
/// crash and never block on a missing account.
public final class CloudKitContainer: DebugPrintable {

    /// Shared instance wired to the real container.
    public static let shared = CloudKitContainer()

    /// The real CloudKit container for this app.
    public static var defaultContainer: CKContainer {
        CKContainer(identifier: CloudKitSchema.containerID)
    }

    private let accountStatusProvider: AccountStatusProviding
    private let zoneProvisioner: RecordZoneProvisioning
    private let zoneLister: RecordZoneListing
    private let subscriptionProvisioner: SubscriptionProvisioning
    private let defaults: UserDefaults

    /// Persisted in the app-group defaults (same store `SyncedDataStore` uses) so
    /// we don't re-issue the zone-create op on every launch. Keyed by the container
    /// identifier: the zone lives inside a specific container, so a flag set for one
    /// container must NOT suppress creation in another (e.g. after the container id
    /// changes, or Debug vs Release). A global key let a stale "created" flag leave
    /// the new container with no zone.
    private var zoneCreatedKey: String { "cloudkit_zone_created_v1_" + CloudKitSchema.containerID }

    public init(
        accountStatusProvider: AccountStatusProviding = CloudKitContainer.defaultContainer,
        zoneProvisioner: RecordZoneProvisioning = CloudKitContainer.defaultContainer.privateCloudDatabase,
        zoneLister: RecordZoneListing = CloudKitContainer.defaultContainer.privateCloudDatabase,
        subscriptionProvisioner: SubscriptionProvisioning = CloudKitContainer.defaultContainer.privateCloudDatabase,
        defaults: UserDefaults = UserDefaults(suiteName: UserDefaultUtils.appGroup) ?? .standard
    ) {
        self.accountStatusProvider = accountStatusProvider
        self.zoneProvisioner = zoneProvisioner
        self.zoneLister = zoneLister
        self.subscriptionProvisioner = subscriptionProvisioner
        self.defaults = defaults
    }

    // MARK: Accessors

    public var container: CKContainer { CloudKitContainer.defaultContainer }
    public var privateDB: CKDatabase { container.privateCloudDatabase }
    public var zoneID: CKRecordZone.ID { CKRecordZone.ID(zoneName: CloudKitSchema.zoneName) }

    // MARK: Account status

    /// Resolves the account status, never throwing — any error collapses to
    /// `.couldNotDetermine` (treated as unavailable).
    public func accountStatus() async -> CKAccountStatus {
        do {
            let status = try await accountStatusProvider.currentAccountStatus()
            printDebug("accountStatus ok status=\(status.rawValue)")
            return status
        } catch {
            // `.couldNotDetermine` is also a legitimate server answer, so without
            // this log an error and a genuine "unknown" are indistinguishable.
            printDebug("accountStatus FAILED error=\(error); collapsing to couldNotDetermine")
            return .couldNotDetermine
        }
    }

    /// CloudKit is usable only when an account is fully available. `.noAccount`,
    /// `.restricted`, and `.couldNotDetermine` all mean "stay local-only".
    public func isCloudKitAvailable() async -> Bool {
        let status = await accountStatus()
        let available = status == .available
        if !available {
            printDebug("isCloudKitAvailable MISS status=\(status.rawValue)")
        }
        return available
    }

    // MARK: Zone bootstrap

    /// Idempotently ensures the custom `EncameraZone` exists. Cheap no-op after the
    /// first success (guarded by a persisted flag). Tolerates "already exists"
    /// races so concurrent launches don't surface a spurious error.
    public func ensureZoneExists() async throws {
        if defaults.bool(forKey: zoneCreatedKey) {
            printDebug("ensureZoneExists skip reason=alreadyCreatedFlag zone=\(CloudKitSchema.zoneName) container=\(CloudKitSchema.containerID)")
            return
        }

        let zone = CKRecordZone(zoneName: CloudKitSchema.zoneName)
        printDebug("ensureZoneExists start zone=\(CloudKitSchema.zoneName) container=\(CloudKitSchema.containerID)")
        do {
            try await zoneProvisioner.saveZone(zone)
            printDebug("ensureZoneExists ok zone=\(CloudKitSchema.zoneName)")
        } catch {
            guard Self.isBenignZoneError(error) else {
                printDebug("ensureZoneExists FAILED zone=\(CloudKitSchema.zoneName) error=\(error)")
                throw error
            }
            // Benign means "already exists"; we still set the flag below.
            printDebug("ensureZoneExists ok zone=\(CloudKitSchema.zoneName) benignError=\(error)")
        }
        defaults.set(true, forKey: zoneCreatedKey)
    }

    /// Resets the cached "zone created" flag (used by migration/teardown paths).
    public func resetZoneCreatedFlag() {
        printDebug("resetZoneCreatedFlag ok container=\(CloudKitSchema.containerID)")
        defaults.set(false, forKey: zoneCreatedKey)
    }

    /// Whether this device ever provisioned the CloudKit zone — i.e. CloudKit
    /// storage was actually used. Read by the eraser to suppress the "iCloud data
    /// may remain" warning for users who never had anything in CloudKit.
    public var hasEverProvisionedZone: Bool {
        defaults.bool(forKey: zoneCreatedKey)
    }

    // MARK: Teardown

    /// Deletes the entire `EncameraZone` from the private database — in one server
    /// operation this removes every `EncMedia` and `EncAlbum` record and all of
    /// their CKAssets. Used by the "Erase All Data" reset to wipe the user's
    /// CloudKit data across all of their devices.
    ///
    /// A zone that does not exist (user never used CloudKit, or already deleted on
    /// another device) is treated as success — there is nothing to remove. Any
    /// other failure (e.g. offline, no account) is surfaced so the caller can warn
    /// that iCloud data may remain.
    public func deleteAllCloudData() async throws {
        printDebug("deleteAllCloudData start zone=\(zoneID.zoneName) container=\(CloudKitSchema.containerID)")
        // Both latches are cleared however this returns. A delete the server
        // committed but the client saw fail — a dropped response, a rate limit —
        // leaves the zone gone; a flag still claiming it exists would make every
        // later write skip the create and fail. Clearing costs one round trip.
        defer {
            resetZoneCreatedFlag()
            defaults.removeObject(forKey: ChunkedBlobSchema.zoneCreatedDefaultsKey)
        }
        do {
            try await zoneProvisioner.deleteZone(zoneID)
            printDebug("deleteAllCloudData ok zone=\(zoneID.zoneName)")
        } catch {
            guard Self.isBenignDeleteError(error) else {
                printDebug("deleteAllCloudData FAILED zone=\(zoneID.zoneName) error=\(error)")
                throw error
            }
            // The zone was already gone — nothing to remove, so this is success.
            printDebug("deleteAllCloudData ok zone=\(zoneID.zoneName) benignError=\(error)")
        }

        // The blob zone too: one zone delete reclaims every chunk record ever
        // written — including unreachable orphans from any earlier bug — which is
        // exactly the guarantee "delete my iCloud data" promises.
        let blobZoneID = CKRecordZone.ID(zoneName: ChunkedBlobSchema.zoneName)
        do {
            try await zoneProvisioner.deleteZone(blobZoneID)
            printDebug("deleteAllCloudData ok zone=\(blobZoneID.zoneName)")
        } catch {
            guard Self.isBenignDeleteError(error) else {
                printDebug("deleteAllCloudData FAILED zone=\(blobZoneID.zoneName) error=\(error)")
                throw error
            }
            printDebug("deleteAllCloudData ok zone=\(blobZoneID.zoneName) benignError=\(error)")
        }
    }

    /// The zone names an erase must leave behind no trace of.
    public static var ownedZoneNames: [String] {
        [CloudKitSchema.zoneName, ChunkedBlobSchema.zoneName]
    }

    /// Owned zones still present on the server. Empty means the delete took.
    public func remainingZoneNames() async throws -> [String] {
        let existing = Set(try await zoneLister.existingZoneIDs().map(\.zoneName))
        let remaining = Self.ownedZoneNames.filter { existing.contains($0) }
        printDebug("remainingZoneNames ok remaining=\(remaining)")
        return remaining
    }

    /// Removes every subscription in the private database. The zone subscription
    /// survives a zone delete, and a stale one would keep pushing silent
    /// notifications at a wiped install.
    public func deleteAllSubscriptions() async throws {
        let ids = try await subscriptionProvisioner.allSubscriptionIDs()
        printDebug("deleteAllSubscriptions start count=\(ids.count)")
        for id in ids {
            do {
                try await subscriptionProvisioner.deleteSubscription(id: id)
            } catch {
                guard Self.isBenignDeleteError(error) else { throw error }
            }
        }
    }

    public func remainingSubscriptionIDs() async throws -> [String] {
        try await subscriptionProvisioner.allSubscriptionIDs()
    }

    /// Deleting a zone that is already gone is harmless; treat the corresponding
    /// CloudKit errors as success.
    static func isBenignDeleteError(_ error: Error) -> Bool {
        guard let ckError = error as? CKError else {
            // A non-CKError here means the failure came from somewhere other than
            // CloudKit, which is never classifiable as "already gone".
            Self.printDebug("isBenignDeleteError MISS reason=notCKError error=\(error)")
            return false
        }
        switch ckError.code {
        case .zoneNotFound, .userDeletedZone:
            Self.printDebug("isBenignDeleteError hit code=\(ckError.code.rawValue)")
            return true
        case .partialFailure:
            let perItem: [AnyHashable: Error] = ckError.partialErrorsByItemID ?? [:]
            let benign = !perItem.isEmpty && perItem.values.allSatisfy { isBenignDeleteError($0) }
            Self.printDebug("isBenignDeleteError partialFailure benign=\(benign) perItemCount=\(perItem.count)")
            return benign
        default:
            Self.printDebug("isBenignDeleteError MISS code=\(ckError.code.rawValue) error=\(ckError)")
            return false
        }
    }

    /// Creating a zone that already exists is harmless; treat the corresponding
    /// CloudKit errors as success so the flag still gets set.
    static func isBenignZoneError(_ error: Error) -> Bool {
        guard let ckError = error as? CKError else {
            Self.printDebug("isBenignZoneError MISS reason=notCKError error=\(error)")
            return false
        }
        switch ckError.code {
        case .serverRecordChanged:
            Self.printDebug("isBenignZoneError hit code=\(ckError.code.rawValue)")
            return true
        case .partialFailure:
            let perItem: [AnyHashable: Error] = ckError.partialErrorsByItemID ?? [:]
            // Benign only if there is at least one underlying failure and every
            // one of them is itself benign.
            let benign = !perItem.isEmpty && perItem.values.allSatisfy { isBenignZoneError($0) }
            Self.printDebug("isBenignZoneError partialFailure benign=\(benign) perItemCount=\(perItem.count)")
            return benign
        default:
            Self.printDebug("isBenignZoneError MISS code=\(ckError.code.rawValue) error=\(ckError)")
            return false
        }
    }
}
