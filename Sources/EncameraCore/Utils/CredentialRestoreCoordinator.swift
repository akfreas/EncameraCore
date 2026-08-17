//
//  CredentialRestoreCoordinator.swift
//  EncameraCore
//
//  Drives the first-launch decision between onboarding and the authenticated
//  app. iCloud Keychain syncs credentials out-of-band at the system level, but
//  offers no API to force, await, or observe a sync — polling the keychain is
//  the only signal. This coordinator bounds that wait so a second device lands
//  on the PIN screen instead of onboarding whenever credentials have arrived
//  (or arrive within the grace window).
//

import Foundation
import Combine

@MainActor
public final class CredentialRestoreCoordinator: ObservableObject, DebugPrintable {

    public enum LaunchState: Equatable {
        /// Initial probe + quiet poll, hidden behind the splash screen.
        case evaluating
        /// Strong hint of an existing account; showing "Restoring from iCloud…".
        case waitingForRestore
        /// Credentials found but the default key is missing; re-deriving it.
        case restoringKeyMaterial
        /// The account was set up before, but backup is off and no key material
        /// is on this device — nothing will ever arrive via iCloud. Turning
        /// backup off on another device tombstones the synced items and the
        /// deletion propagates here, so this is the expected aftermath, not an
        /// error. The user needs an explanation and a recovery entrypoint.
        case keyMissing
        /// Key material is present but no password hash is — the always-synced
        /// `AuthenticationConfiguration` can claim a passcode is set while the
        /// hash that would verify it never synced. The unlock screen would be
        /// unsatisfiable, so the user sets a new passcode instead. The existing
        /// key is preserved; see `AuthStateMatrix`.
        case passcodeSetup
        case onboarding
        case main

        /// False while launch-time credentials are still in flight. CloudKit
        /// album reconciliation must not run before this turns true: it matches
        /// synced keys against a one-way album-id hash, so a pass made mid-wait
        /// reports every remote album as unmaterializable and empties the grid.
        /// `.keyMissing` is terminal — nothing further will arrive — so the
        /// reconciler is allowed to run and report its locked-out count.
        public var allowsCloudKitSync: Bool {
            switch self {
            case .evaluating, .waitingForRestore, .restoringKeyMaterial:
                return false
            case .keyMissing, .passcodeSetup, .onboarding, .main:
                return true
            }
        }
    }

    /// Lock-guarded mirror of `state.allowsCloudKitSync`, readable from the
    /// `CloudKitAlbumsSync` actor without hopping to the main actor.
    public final class SyncGate: @unchecked Sendable {
        private let lock = NSLock()
        private var _isOpen: Bool

        public init(isOpen: Bool = false) {
            self._isOpen = isOpen
        }

        public var isOpen: Bool {
            get { lock.withLock { _isOpen } }
            set { lock.withLock { _isOpen = newValue } }
        }
    }

    public struct Timeouts {
        public let quietGrace: TimeInterval
        public let restoreWait: TimeInterval
        public let pollDelays: [TimeInterval]

        public init(quietGrace: TimeInterval = AppConstants.keychainRestoreQuietGrace,
                    restoreWait: TimeInterval = AppConstants.keychainRestoreWaitTimeout,
                    pollDelays: [TimeInterval] = [0.25, 0.5, 1.0, 2.0]) {
            self.quietGrace = quietGrace
            self.restoreWait = restoreWait
            self.pollDelays = pollDelays
        }
    }

    @Published public private(set) var state: LaunchState = .evaluating

    private let keyManager: KeyManager
    private let isiCloudAvailable: () -> Bool
    private let kvsOnboardingCompleted: () -> Bool
    private let timeouts: Timeouts
    private let sleep: (TimeInterval) async -> Void
    private var resolved = false

    public init(keyManager: KeyManager,
                isiCloudAvailable: @escaping () -> Bool = { FileManager.default.ubiquityIdentityToken != nil },
                kvsOnboardingCompleted: @escaping () -> Bool = CredentialRestoreCoordinator.defaultKVSOnboardingCompleted,
                timeouts: Timeouts = Timeouts(),
                sleep: @escaping (TimeInterval) async -> Void = { seconds in
                    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                }) {
        self.keyManager = keyManager
        self.isiCloudAvailable = isiCloudAvailable
        self.kvsOnboardingCompleted = kvsOnboardingCompleted
        self.timeouts = timeouts
        self.sleep = sleep
    }

    /// True when the KVS-synced onboarding state says the user completed
    /// onboarding on another device — a strong hint that keychain credentials
    /// are on their way even if they haven't landed yet.
    public static func defaultKVSOnboardingCompleted() -> Bool {
        guard let data = UserDefaultUtils.data(forKey: .onboardingState) else {
            printDebug("KVS hint: no onboardingState present in defaults/KVS")
            return false
        }
        guard let state = try? JSONDecoder().decode(OnboardingState.self, from: data) else {
            printDebug("KVS hint: onboardingState present but undecodable (\(data.count) bytes)")
            return false
        }
        printDebug("KVS hint: onboardingState = \(state)")
        return state == .completed
    }

    public func start() async {
        guard state == .evaluating, !resolved else {
            printDebug("start() ignored — state=\(state), resolved=\(resolved)")
            return
        }

        let startedAt = Date()
        printDebug("start() — quietGrace=\(timeouts.quietGrace)s, restoreWait=\(timeouts.restoreWait)s, pollDelays=\(timeouts.pollDelays)")

        var snapshot = keyManager.credentialSnapshot()
        printDebug("initial snapshot: \(snapshot)")

        if snapshot.passwordExists {
            printDebug("password already present at first probe → resolving with credentials")
            await resolveWithCredentials(snapshot)
            return
        }

        // A synced "backup disabled" flag or no iCloud account means nothing
        // will ever arrive — don't make a new user wait.
        let iCloudAvailable = isiCloudAvailable()
        printDebug("no password at first probe — iCloudAvailable=\(iCloudAvailable), backupFlag=\(snapshot.backupFlagState)")
        if snapshot.backupFlagState == .disabled {
            resolveForDisabledBackup(snapshot)
            return
        }
        if !iCloudAvailable {
            printDebug("nothing will arrive (no iCloud account) → onboarding immediately")
            resolve(.onboarding)
            return
        }

        let kvsHint = kvsOnboardingCompleted()
        var strongHint = kvsHint || snapshot.backupFlagState == .enabled || snapshot.hasAnyCredential
        printDebug("hints: kvsOnboardingCompleted=\(kvsHint), backupFlagEnabled=\(snapshot.backupFlagState == .enabled), hasAnyCredential=\(snapshot.hasAnyCredential) → strongHint=\(strongHint)")
        if strongHint {
            printDebug("strong hint → showing waitingForRestore, extending deadline to \(timeouts.restoreWait)s")
            state = .waitingForRestore
        }

        var deadline = strongHint ? timeouts.restoreWait : timeouts.quietGrace
        var elapsed: TimeInterval = 0
        var delayIndex = 0

        while elapsed < deadline {
            let baseDelay = timeouts.pollDelays[min(delayIndex, timeouts.pollDelays.count - 1)]
            let delay = min(baseDelay, deadline - elapsed)
            delayIndex += 1
            await sleep(delay)
            elapsed += delay

            if resolved {
                printDebug("poll #\(delayIndex): resolved externally while sleeping (state=\(state)) — stopping")
                return
            }

            snapshot = keyManager.credentialSnapshot()
            printDebug("poll #\(delayIndex) (elapsed \(String(format: "%.2f", elapsed))s/\(deadline)s): \(snapshot)")

            if snapshot.passwordExists {
                printDebug("password arrived after \(String(format: "%.2f", Date().timeIntervalSince(startedAt)))s → resolving with credentials")
                await resolveWithCredentials(snapshot)
                return
            }
            if snapshot.backupFlagState == .disabled {
                printDebug("synced backup-disabled flag arrived mid-poll")
                resolveForDisabledBackup(snapshot)
                return
            }
            if !strongHint && (kvsOnboardingCompleted() || snapshot.backupFlagState == .enabled || snapshot.hasAnyCredential) {
                strongHint = true
                state = .waitingForRestore
                deadline = timeouts.restoreWait
                printDebug("hint appeared mid-poll → upgrading to waitingForRestore, deadline now \(deadline)s")
            }
        }

        printDebug("deadline reached after \(String(format: "%.2f", elapsed))s with no credentials → onboarding")
        resolve(.onboarding)
    }

    /// Backup is off, so no credentials will ever arrive. A true fresh install
    /// goes to onboarding; a device with prior-setup hints (the KVS-synced
    /// onboarding state or leftover credential fragments) gets the key-missing
    /// screen instead of being treated like a new user.
    private func resolveForDisabledBackup(_ snapshot: KeychainCredentialSnapshot) {
        let previouslySetUp = kvsOnboardingCompleted() || snapshot.hasAnyCredential
        if previouslySetUp {
            printDebug("backup disabled but prior-setup hints present → keyMissing")
            resolve(.keyMissing)
        } else {
            printDebug("backup disabled and no prior-setup hints → onboarding")
            resolve(.onboarding)
        }
    }

    /// User tapped "Set up as a new device" on the restore screen.
    public func userChoseSetUpAsNew() {
        printDebug("user chose 'Set up as a new device'")
        resolved = true
        state = .onboarding
        printDebug("RESOLVED → onboarding (user choice)")
    }

    /// External signal (e.g. a KVS key arrived) that credentials may now be
    /// present. Safe to call at any time; no-op once resolved — except from
    /// keyMissing, which un-resolves when credentials arrive (the user
    /// re-enabled backup on another device while the screen was up).
    public func credentialsMayHaveChanged() {
        if resolved, state == .keyMissing, keyManager.credentialSnapshot().passwordExists {
            printDebug("credentials arrived while on keyMissing → re-resolving")
            resolved = false
        }
        // A key can arrive without its password hash (backup was on for keys
        // but the hash predates it, or the hash was never synchronizable). The
        // key-missing screen is then simply wrong.
        if resolved, state == .keyMissing, keyManager.needsPasscodeSetup {
            printDebug("key arrived while on keyMissing but no password hash → passcodeSetup")
            resolved = true
            state = .passcodeSetup
            return
        }
        guard !resolved else {
            printDebug("credentialsMayHaveChanged() ignored — already resolved (state=\(state))")
            return
        }
        let snapshot = keyManager.credentialSnapshot()
        printDebug("credentialsMayHaveChanged(): \(snapshot)")
        if snapshot.passwordExists {
            printDebug("password present on external signal → resolving with credentials")
            Task { await resolveWithCredentials(snapshot) }
        }
    }

    private func resolveWithCredentials(_ snapshot: KeychainCredentialSnapshot) async {
        guard !resolved else {
            printDebug("resolveWithCredentials ignored — already resolved (state=\(state))")
            return
        }
        if !snapshot.defaultKeyExists && snapshot.passphraseExists {
            printDebug("default key missing but passphrase present → restoringKeyMaterial (re-deriving)")
            state = .restoringKeyMaterial
            let keyManager = self.keyManager
            // pwHash derivation is CPU-bound; keep it off the main actor.
            let result: Result<Bool, Error> = await Task.detached(priority: .userInitiated) {
                do {
                    return .success(try keyManager.restoreDefaultKeyFromPassphraseIfNeeded())
                } catch {
                    return .failure(error)
                }
            }.value
            switch result {
            case .success(let restored):
                printDebug("key restore finished — restored=\(restored)")
            case .failure(let error):
                printDebug("key restore FAILED:", error)
            }
        } else if !snapshot.defaultKeyExists {
            printDebug("default key missing and NO passphrase yet — proceeding to main; unlock-time heal hook will retry when items arrive")
        }
        // Even if the key is still missing (passphrase not yet synced), proceed
        // to main: authentication works with the password hash alone and the
        // unlock-time heal hook restores the key when its items arrive.
        resolve(.main)
    }

    private func resolve(_ requestedState: LaunchState) {
        guard !resolved else {
            printDebug("resolve(\(requestedState)) ignored — already resolved (state=\(state))")
            return
        }
        let finalState = redirectingToPasscodeSetupIfNeeded(requestedState)
        resolved = true
        state = finalState
        printDebug("RESOLVED → \(finalState)")
    }

    /// Single choke point for the auth-state matrix cells where this device
    /// holds key material but no password hash: `(config, no hash, key)` and
    /// `(no config, no hash, key)`.
    ///
    /// Both would otherwise land on onboarding-from-scratch or the key-missing
    /// screen, neither of which is true — the key is right here. Onboarding
    /// would also let the user create a second, diverging account alongside a
    /// key they already own.
    private func redirectingToPasscodeSetupIfNeeded(_ requestedState: LaunchState) -> LaunchState {
        guard requestedState == .onboarding || requestedState == .keyMissing else {
            return requestedState
        }
        guard keyManager.needsPasscodeSetup else {
            return requestedState
        }
        printDebug("\(requestedState) requested but a key exists with no password hash → passcodeSetup")
        return .passcodeSetup
    }
}
