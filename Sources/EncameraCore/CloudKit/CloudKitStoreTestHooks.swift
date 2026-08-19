//
//  CloudKitStoreTestHooks.swift
//  EncameraCore
//
//  UI-test-only fault-injection points for the CloudKit store. All hooks default
//  to inert values; the app sets them from launch arguments inside
//  `UITestMode.setupIfNeeded()`, so production builds are unaffected.
//

import Foundation

/// Test-only configuration `CloudKitMediaStore` consults so a UI test can make a
/// delete fail the way a device with no connectivity does.
///
/// Deletes are the one operation whose durability cannot be observed any other
/// way. The intent is written to a durable queue BEFORE the server call precisely
/// so a delete made offline, or interrupted by termination, is retried later — and
/// the only honest way to test that is to make the server call fail, kill the app,
/// and watch the record disappear anyway. Toggling real connectivity would mean
/// driving Settings from the test process, which is both fragile and outside the
/// app under test.
public enum CloudKitStoreTestHooks {

    /// When true, `delete(recordName:)` and `deleteAlbum(albumID:)` throw
    /// `CloudKitMediaStoreError.retry` — the same classification a transient
    /// connectivity failure maps to — without contacting the server. Everything
    /// else — uploads, fetches, the change feed — still works, which is what makes
    /// this a connectivity simulation for the delete path rather than an offline
    /// app: the queued intent has to survive on its own merits.
    public static var failDeletes: Bool = false
}
