//
//  LockedAlbumsReporter.swift
//  EncameraCore
//
//  Carries the reconciler's locked-out album count to the UI (ENC-99).
//

import Foundation
import Combine

/// Publishes how many CloudKit albums exist on the account but cannot be shown
/// on this device because their key is absent.
///
/// `CloudKitAlbumReconciler.reconcileAlbums()` has returned this count since it
/// was written, and `CloudKitAlbumsSync.albumsNeedingKey` has stored it — but
/// the sync actor is held privately by `EncameraApp` and never reaches
/// `AlbumGridViewModel`, so the count had no consumer and locked albums were
/// simply missing from the grid with nothing said about it (the `//TODO: We have
/// to surface this!` in the reconciler).
///
/// A shared singleton rather than another injected dependency: the producer is
/// an actor rebuilt on every key change and the consumer is a view model built
/// independently, so there is no common owner to thread this through.
@MainActor
public final class LockedAlbumsReporter: ObservableObject {

    public static let shared = LockedAlbumsReporter()

    /// Remote albums that could not be materialized for lack of a key, as of the
    /// last completed reconcile. Zero when everything is readable.
    @Published public private(set) var lockedAlbumCount: Int = 0

    public init() {}

    public func report(lockedAlbumCount count: Int) {
        guard count != lockedAlbumCount else { return }
        lockedAlbumCount = count
    }
}
