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
    case biometrics
    case biometricsWithPin
    case setPinCode
    case confirmPinCode
    case finished
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
        case (.settingsManagerError(let error1), .settingsManagerError(let error2)):
            return error1 == error2
        default:
            return false            
        }
    }
    
    case couldNotSerialize
    case couldNotDeserialize
    case couldNotGetFromUserDefaults
    case incorrectStateForOperation
    case settingsManagerError(SettingsManagerError)
    case unknownError
}

public protocol OnboardingManaging {
    init(keyManager: KeyManager, authManager: AuthManager, settingsManager: SettingsManager)
    func saveOnboardingState(_ state: OnboardingState, settings: SavedSettings) async throws
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
    private var settingsManager: SettingsManager
    
    public required init(keyManager: KeyManager, authManager: AuthManager, settingsManager: SettingsManager) {
        self.keyManager = keyManager
        self.authManager = authManager
        self.settingsManager = settingsManager
        self.observables = OnboardingManagerObservable()
    }
    
    func clearOnboardingState() {
        UserDefaultUtils.removeObject(forKey: .onboardingState)
    }
    
    func validate(state: OnboardingState, settings: SavedSettings) throws {

        guard case .completed = state else {
            throw OnboardingManagerError.incorrectStateForOperation
        }
        
        do {
            try settingsManager.validate(settings)
        } catch let validationError as SettingsManagerError {
            throw OnboardingManagerError.settingsManagerError(validationError)
        }
        
    }
    
    public func saveOnboardingState(_ state: OnboardingState, settings: SavedSettings) async throws {

        switch state {
        case .completed:
            try validate(state: state, settings: settings)
            do {
                try settingsManager.saveSettings(settings)
            } catch let settingsError as SettingsManagerError {
                throw OnboardingManagerError.settingsManagerError(settingsError)
            } catch {
                throw OnboardingManagerError.unknownError
            }
            
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
                try await saveOnboardingState(.completed, settings: SavedSettings(useBiometricsForAuth: true))
            }
            UserDefaultUtils.set(true, forKey: .usesPinPassword)
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
