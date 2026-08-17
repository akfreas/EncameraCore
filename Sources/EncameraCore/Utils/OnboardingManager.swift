//
//  OnboardingManager.swift
//  Encamera
//
//  Created by Alexander Freas on 14.07.22.
//

import Foundation


public enum OnboardingState: Codable, Equatable {
    case completed
    case notStarted
    case hasPasswordAndNotOnboarded
    case hasOnboardingAndNoPassword

    func showOnboarding() -> Bool {
        let show: Bool
        switch self {
        case .completed:
            show = false
        case .notStarted:
            show = true
        case .hasPasswordAndNotOnboarded:
            show = true
        case .hasOnboardingAndNoPassword:
            show = true
        }
        return show
    }
}


public enum OnboardingFlowScreen: String, Identifiable {
    case intro
    case enterExistingPassword
    case setPassword
    case enterPassword
    case confirmPassword
    case biometrics
    case biometricsWithPin
    case setPinCode
    case confirmPinCode
    case showKeyPhrase
    /// iCloud Multi-Device Mode opt-in (ENC-95), shown AFTER auth setup and BEFORE
    /// the app opens. Offers the mode defaulted OFF (no pre-check, explicit tap
    /// required), with the honest framing that the key lives in the user's iCloud
    /// Keychain. Gated on `.keychainSyncRestore`; skipped for a user who already
    /// arrived through a recovery path or already has sync on. Handled in
    /// `handleNavigationFor`, never `fatalError`.
    case multiDeviceOptIn
    /// Returning-user branch shown when the existing-data probe (ENC-90) returns
    /// `.found`. Genuine new users (`.none`/`.unknown`) never reach it.
    case returningUserBranch
    /// Manual key-phrase entry for the "I have my key" happy path (ENC-92):
    /// paste/type the phrase, validate it against the fingerprints the existing
    /// data needs, and accept it additively. Handled in `handleNavigationFor`,
    /// never `fatalError`.
    case returningUserManualKeyEntry
    /// Placeholder destination retained for the guided flip-the-switch recovery
    /// flow that lands in ENC-93. Handled in `handleNavigationFor`, never
    /// `fatalError`.
    case returningUserRecoveryPlaceholder
    /// Guided flip-the-switch recovery (ENC-93): the second "I have my key" path,
    /// for a user who still has their other device but not the key phrase. Waits
    /// for the key to arrive via iCloud Keychain (polling the ENC-68 credential
    /// coordinator), with a mandatory timeout, fingerprint verification on
    /// arrival, and a manual-entry fallback. Handled in `handleNavigationFor`,
    /// never `fatalError`.
    case returningUserGuidedSync
    /// Placeholder destination for "I don't have my key" — retained for the guided
    /// recovery follow-ups. The live destructive flow lands in the three screens
    /// below. Handled in `handleNavigationFor`, never `fatalError`.
    case returningUserDestructivePlaceholder
    /// Destructive delete-my-iCloud-data path (ENC-94), the "I don't have my key"
    /// branch. Three escalating confirmations, each handled in `handleNavigationFor`
    /// and never `fatalError`; a back-out at any of them cancels the whole flow
    /// (nothing is deleted until the hold completes on the third).
    ///
    /// Screen 1 — what exists: counts + advisory device names from the probe.
    case returningUserDestructiveConfirm
    /// Screen 2 — what it means: unrecoverable, no recovery, crypto-wallet framing.
    case returningUserDestructiveWarning
    /// Screen 3 — hold-to-delete (reusing `HoldToConfirmButton`), gated on being
    /// online. On success: fresh key + normal auth. On partial failure: honest report.
    case returningUserDestructiveHold
    public var id: Self { self }
}

public enum OnboardingManagerError: Error, Equatable {
    public static func == (lhs: OnboardingManagerError, rhs: OnboardingManagerError) -> Bool {
        switch (lhs, rhs) {
        case (.couldNotSerialize, .couldNotSerialize):
            return true
        case (.couldNotDeserialize, .couldNotDeserialize):
            return true
        case (.couldNotGetFromUserDefaults, .couldNotGetFromUserDefaults):
            return true
        case (.incorrectStateForOperation, .incorrectStateForOperation):
            return true
        case (.unknownError, .unknownError):
            return true
        case (.couldNotSerialize, _), (_, .couldNotSerialize),
             (.couldNotDeserialize, _), (_, .couldNotDeserialize),
             (.couldNotGetFromUserDefaults, _), (_, .couldNotGetFromUserDefaults),
             (.incorrectStateForOperation, _), (_, .incorrectStateForOperation),
             (.unknownError, _), (_, .unknownError):
            return false
        }
    }
    
    case couldNotSerialize
    case couldNotDeserialize
    case couldNotGetFromUserDefaults
    case incorrectStateForOperation
    case unknownError
}

public protocol OnboardingManaging {
    init(keyManager: KeyManager, authManager: AuthManager)
    func saveOnboardingState(_ state: OnboardingState, authenticationConfiguration: AuthenticationConfiguration) async throws
}

public class OnboardingManagerObservable {
    @Published public var onboardingState: OnboardingState = .notStarted {
        didSet {
            shouldShowOnboarding = onboardingState.showOnboarding()
        }
    }

    @Published public var shouldShowOnboarding: Bool = true
    

}

public class OnboardingManager: OnboardingManaging {
    
    private enum Constants {
        static var onboardingStateKey = "onboardingState"
    }
    public var observables: OnboardingManagerObservable
    
    private var keyManager: KeyManager
    private var authManager: AuthManager

    public required init(keyManager: KeyManager, authManager: AuthManager) {
        self.keyManager = keyManager
        self.authManager = authManager
        self.observables = OnboardingManagerObservable()
    }
    
    func clearOnboardingState() {
        UserDefaultUtils.removeObject(forKey: .onboardingState)
    }
    
    public func saveOnboardingState(_ state: OnboardingState, authenticationConfiguration: AuthenticationConfiguration) async throws {

        switch state {
        case .completed:
            try keyManager.setAuthenticationConfiguration(config: authenticationConfiguration)

        case .notStarted,
             .hasPasswordAndNotOnboarded,
             .hasOnboardingAndNoPassword:
            return
        }
        do {
            let data = try JSONEncoder().encode(state)
            UserDefaultUtils.set(data, forKey: .onboardingState)
        } catch {
            throw OnboardingManagerError.couldNotSerialize
        }
        
        await MainActor.run {
            observables.onboardingState = state
        }
        

    }
    
    @discardableResult public func loadOnboardingState() throws -> OnboardingState {
        let state = try getOnboardingStateFromDefaults()

        if state == .hasPasswordAndNotOnboarded {
            Task {
                let configuration = keyManager.getAuthenticationConfiguration() ?? AuthenticationConfiguration(enabledTypes: [.passcode(.password)])
                try await saveOnboardingState(.completed, authenticationConfiguration: configuration)
            }

            return .completed
        }
        observables.onboardingState = state
        return observables.onboardingState
    }
}

private extension OnboardingManager {
    func getOnboardingStateFromDefaults() throws -> OnboardingState {
        let passwordExists = keyManager.passwordExists()
        
        guard let savedState = UserDefaultUtils.data(forKey: .onboardingState) else {
            if passwordExists {
                return .hasPasswordAndNotOnboarded
            }
            
            return .notStarted
        }
        
        do {
            
            let state = try JSONDecoder().decode(OnboardingState.self, from: savedState)
            if case .completed = state, passwordExists == false && authManager.useBiometricsForAuth == false {
                return .hasOnboardingAndNoPassword
            }
            
            return state
        } catch {
            
            throw OnboardingManagerError.couldNotDeserialize
        }
    }
}
