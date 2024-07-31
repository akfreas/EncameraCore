import Foundation


public class DemoOnboardingManager: OnboardingManaging {
    required public init(keyManager: KeyManager = DemoKeyManager(), authManager: AuthManager = DemoAuthManager(), settingsManager: SettingsManager = SettingsManager()) {

    }

    public func generateOnboardingFlow() -> [OnboardingFlowScreen] {
        return [.setPinCode]
    }

    public func saveOnboardingState(_ state: OnboardingState, settings: SavedSettings) async throws {

    }


}
