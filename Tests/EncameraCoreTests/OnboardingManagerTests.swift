//
//  OnboardingManagerTests.swift
//  EncameraTests
//
//  Created by Alexander Freas on 15.07.22.
//

import Foundation
import XCTest
import Combine
@testable import EncameraCore

class OnboardingManagerTests: XCTestCase {
    
    
    private var manager: OnboardingManager!
    private var keyManager: DemoKeyManager!
    private var authManager: DemoAuthManager!
    private var cancellables = Set<AnyCancellable>()
    override func setUp() {
        authManager = DemoAuthManager()
        keyManager = DemoKeyManager()
        manager = OnboardingManager(
            keyManager: keyManager,
            authManager: authManager,
            settingsManager: SettingsManager()
        )
        manager.clearOnboardingState()
        
    }
    
    func testSaveCompletedOnboardingState() async throws {
        
        let state = OnboardingState.completed
        let settings = SavedSettings(useBiometricsForAuth: true)
        
        try await manager.saveOnboardingState(state, settings: settings)
        keyManager.password = "123"
        let savedState = try manager.loadOnboardingState()
        XCTAssertEqual(state, savedState)
        
    }
    
    func testPublishedOnSave() async throws {
        let state = OnboardingState.completed
        let settings = SavedSettings(useBiometricsForAuth: true)
        var publishedState: OnboardingState?
        let expect = expectation(description: "waiting for published state")
        manager.observables.$onboardingState.dropFirst().sink { published in
            publishedState = published
            expect.fulfill()
        }.store(in: &cancellables)
        
        try await manager.saveOnboardingState(state, settings: settings)
        await waitForExpectations(timeout: 1.0)
        
        XCTAssertEqual(publishedState, state)
    }
    
    func testPublishedOnGet() async throws {
        let state = OnboardingState.completed
        let settings = SavedSettings(useBiometricsForAuth: true)
        var publishedState: OnboardingState?
        let expect = expectation(description: "waiting for published state")
        try await manager.saveOnboardingState(state, settings: settings)
        keyManager.password = "123"
        
        manager.observables.$onboardingState.dropFirst().sink { published in
            publishedState = published
            expect.fulfill()
        }.store(in: &cancellables)
        
        _ = try manager.loadOnboardingState()
        
        await waitForExpectations(timeout: 1.0)
        
        XCTAssertEqual(publishedState, state)

    }
    
    func testUserHasStoredPasswordButNoState() async throws {
        keyManager.password = "password"
        let state = try manager.loadOnboardingState()
        
        XCTAssertEqual(state, .hasPasswordAndNotOnboarded)
    }
    
    func testOnboardingStateValidationCompletedIncorrectSavedInfo() throws {
        let settings = SavedSettings(useBiometricsForAuth: nil)
        let state = OnboardingState.completed
        
        
        XCTAssertThrowsError(try manager.validate(state: state, settings: settings), "Validation error") { error in
            let onboardingError = try? XCTUnwrap(error as? OnboardingManagerError)
            XCTAssertEqual(onboardingError, .settingsManagerError(.validationFailed(SettingsValidation.invalid([ (SavedSettings.CodingKeys.useBiometricsForAuth, "useBiometricsForAuth must be set")]))))
        }
    }
    
    func testOnboardingStateValidationCompletedNoPassword() throws {
        let settings = SavedSettings(useBiometricsForAuth: nil)
        let state = OnboardingState.completed
        
        XCTAssertThrowsError(try manager.validate(state: state, settings: settings))
        
        XCTAssertThrowsError(try manager.validate(state: state, settings: settings), "Validation error") { error in
            let onboardingError = try? XCTUnwrap(error as? OnboardingManagerError)
            XCTAssertEqual(onboardingError, .settingsManagerError(.validationFailed(SettingsValidation.invalid([
                (SavedSettings.CodingKeys.useBiometricsForAuth, "useBiometricsForAuth must be set")
            ]))))
        }
    }
    
    func testLoadOnboardingStateNotStarted() throws {
        let state = try manager.loadOnboardingState()
        XCTAssertEqual(state, .notStarted)
        XCTAssertEqual(manager.observables.onboardingState, .notStarted)
    }
    
    func testLoadOnboardingStateDeserializationFailed() throws {
        UserDefaultUtils.set(try! JSONEncoder().encode(["hey"]), forKey: .onboardingState)
        XCTAssertThrowsError(try manager.loadOnboardingState(), "load onboarding state") { error in
            guard let error = error as? OnboardingManagerError else {
                XCTFail("unknown error \(error)")
                return
            }
            XCTAssertEqual(error, .couldNotDeserialize)
        }
        XCTAssertEqual(manager.observables.onboardingState, .notStarted)

    }
    
    func testOnboardedButNoPassword() async throws {
        let settings = SavedSettings(useBiometricsForAuth: true)
        let state = OnboardingState.completed
        
        try await manager.saveOnboardingState(state, settings: settings)
        keyManager.password = nil
        let saved = try manager.loadOnboardingState()
        XCTAssertEqual(saved, .completed)
    }
    
    func testShouldShowOnboardingCompleted() async throws {
        let settings = SavedSettings(useBiometricsForAuth: true)
        let state = OnboardingState.completed
        keyManager.password = "123"
        try await manager.saveOnboardingState(state, settings: settings)
        try manager.loadOnboardingState()
        XCTAssertFalse(manager.observables.shouldShowOnboarding)
    }
    
    func testShouldShowOnboardingStateNotStarted() throws {
        try manager.loadOnboardingState()
        XCTAssertTrue(manager.observables.shouldShowOnboarding)
    }
    
    func testShouldNotShowOnboardingStateNoPassword() async throws {
        let settings = SavedSettings(useBiometricsForAuth: true)
        let state = OnboardingState.completed
        try await manager.saveOnboardingState(state, settings: settings)
        keyManager.password = nil
        try manager.loadOnboardingState()
        XCTAssertFalse(manager.observables.shouldShowOnboarding)
    }

    func testShouldNotShowOnboardingStateBiometricsOnly() async throws {
        let settings = SavedSettings(useBiometricsForAuth: true)
        let state = OnboardingState.completed
        try await manager.saveOnboardingState(state, settings: settings)
        keyManager.password = nil
        try manager.loadOnboardingState()
        XCTAssertFalse(manager.observables.shouldShowOnboarding)
    }


    func testShouldShowOnboardingStatePasswordNotOnboarded() async throws {
        try keyManager.setPassword("password")
        try manager.loadOnboardingState()
        XCTAssertTrue(manager.observables.shouldShowOnboarding)

    }
}
