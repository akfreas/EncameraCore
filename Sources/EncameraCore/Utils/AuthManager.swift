//
//  AuthManager.swift
//  Encamera
//
//  Created by Alexander Freas on 06.12.21.
//

import Foundation
import LocalAuthentication
import Combine
import UIKit

public enum AuthManagerError: Error {
    case passwordIncorrect
    case biometricsFailed
    case biometricsNotAvailable
    case userCancelledBiometrics
}

public enum AuthenticationMethod: Codable {
    case touchID
    case faceID
    case password
    
    public var nameForMethod: String {
        switch self {
        case .touchID:
            return L10n.touchID
        case .faceID:
            return L10n.faceID
        case .password:
            return L10n.password
        }
    }
    
    public var imageNameForMethod: String {
        switch self {
            
        case .touchID:
            return "touchid"
        case .faceID:
            return "faceid"
        case .password:
            return "rectangle.and.pencil.and.ellipsis"
        }
    }
    
    public static func methodFrom(biometryType: LABiometryType) -> AuthenticationMethod? {
        switch biometryType {
        case .none:
            return nil
        case .touchID:
            return .touchID
        case .faceID:
            return .faceID
        case .opticID:
            return nil
        @unknown default:
            return nil

        }
    }
}

public enum AuthManagerState: Equatable {
    case authenticated(with: AuthenticationMethod)
    case unauthenticated
}

struct AuthenticationPolicy: Codable {
    var preferredAuthenticationMethod: AuthenticationMethod
    var authenticationExpirySeconds: Int
    
    static var defaultPolicy: AuthenticationPolicy {
        return AuthenticationPolicy(preferredAuthenticationMethod: .password, authenticationExpirySeconds: 60)
    }

    /// The biometry this state refers to, when the probe could tell. Lockout
    /// and per-app denial do not carry one, so callers that know the device's
    /// biometry type pass it to `cannotUnlockMessage(biometryName:)`.
    public var method: AuthenticationMethod? {
        guard case .available(let method) = self else { return nil }
        return method
    }

    /// Why the app cannot be unlocked, for the lock screen of an account with
    /// no passcode. Every case answers, because a user staring at a screen
    /// that will not open needs to know whether to lock and unlock the phone,
    /// visit Settings, or give up and erase.
    ///
    /// `biometryName` is what to call the biometry in the sentence; the states
    /// that do not carry a method take it from the caller, which can still ask
    /// the device.
    public func cannotUnlockMessage(biometryName: String = L10n.BiometricAvailability.genericName) -> String {
        switch self {
        case .available(let method):
            // Usable hardware, but not switched on for Encamera on this
            // device — the per-device consent has not been answered here.
            return L10n.BiometricAvailability.CannotUnlock.notEnabled(method.nameForMethod)
        case .lockedOut:
            return L10n.BiometricAvailability.CannotUnlock.lockedOut(biometryName)
        case .deniedBySystemSettings:
            return L10n.BiometricAvailability.CannotUnlock.deniedBySystemSettings(biometryName)
        case .notEnrolled:
            return L10n.BiometricAvailability.CannotUnlock.notEnrolled
        case .passcodeNotSet:
            return L10n.BiometricAvailability.CannotUnlock.passcodeNotSet
        case .noHardware:
            return L10n.BiometricAvailability.CannotUnlock.noHardware
        case .unavailable(let code):
            return L10n.BiometricAvailability.CannotUnlock.unavailable(code)
        }
    }
}

public protocol AuthManager {
    var isAuthenticatedPublisher: AnyPublisher<Bool, Never> { get }
    var isAuthenticated: Bool { get }
    var availableBiometric: AuthenticationMethod? { get }
    var useBiometricsForAuth: Bool { get set }
    var canAuthenticateWithBiometrics: Bool { get }
    var deviceBiometryType: AuthenticationMethod? { get }
    func deauthorize()
    func authorize(with password: String, using keyManager: KeyManager) throws
    func authorizeWithBiometrics() async throws
    @discardableResult func evaluateWithBiometrics() async throws -> Bool
    func waitForAuthResponse() async -> AuthManagerState
}

public class DeviceAuthManager: AuthManager {
    
    // MARK: - LAContext Caching
    
    /// Cached LAContext instance to avoid expensive recreation on every access.
    /// Creating a new LAContext and calling canEvaluatePolicy involves significant
    /// system security framework overhead, which can cause delays during authentication.
    private var _cachedContext: LAContext?
    
    /// Returns a cached LAContext, creating one only if needed.
    /// The context is invalidated on background or after certain auth events.
    private var context: LAContext {
        if let existing = _cachedContext {
            return existing
        }
        let newContext = LAContext()
        newContext.localizedCancelTitle = L10n.cancel
        _cachedContext = newContext
        return newContext
    }
    
    /// Invalidates the cached LAContext. Call this when the context may be stale
    /// (e.g., after going to background, after failed biometric attempts).
    private func invalidateContext() {
        _cachedContext?.invalidate()
        _cachedContext = nil
        // Also reset cached biometric availability since it depends on context
        _biometricAvailabilityChecked = false
        _cachedAvailableBiometric = nil
    }
    
    // MARK: - Biometric Availability Caching
    
    /// Cached result of biometric availability check
    private var _cachedAvailableBiometric: AuthenticationMethod?
    /// Flag to track if we've already checked biometric availability
    private var _biometricAvailabilityChecked = false
    
    // MARK: - Biometric Authentication Debouncing
    
    /// Timestamp of last biometric attempt for debouncing
    private var lastBiometricAttemptTime: Date?
    
    /// Minimum interval between biometric attempts (in seconds)
    private let biometricDebounceInterval: TimeInterval = 1.0
    
    /// Flag to track if biometric authentication is currently in progress
    private var isBiometricAuthInProgress = false
    
    public var availableBiometric: AuthenticationMethod? {
        // Return cached result if we've already checked
        if _biometricAvailabilityChecked {
            return _cachedAvailableBiometric
        }
        
        // Perform the check and cache the result
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else {
            _biometricAvailabilityChecked = true
            _cachedAvailableBiometric = nil
            return nil
        }
        
        _cachedAvailableBiometric = deviceBiometryType
        _biometricAvailabilityChecked = true
        return _cachedAvailableBiometric
    }

    public var deviceBiometryType: AuthenticationMethod? {
        // Use the cached context to check biometry type
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        return AuthenticationMethod.methodFrom(biometryType: context.biometryType)
    }

    var _useBiometricsForAuth: Bool?
    public var useBiometricsForAuth: Bool {
        get {
            if let _useBiometricsForAuth = self._useBiometricsForAuth {
                return _useBiometricsForAuth
            }
            guard let settings = try? settingsManager.loadSettings(),
                  let useBiometrics = settings.useBiometricsForAuth, deviceBiometryType != .none  else {
                return false
            }
            self._useBiometricsForAuth = useBiometrics
            return useBiometrics
        }
        set(value) {
            self._useBiometricsForAuth = value
            try? settingsManager.saveSettings(SavedSettings(useBiometricsForAuth: value))
        }
    }
    
    public var isAuthenticatedPublisher: AnyPublisher<Bool, Never> {
        isAuthenticatedSubject.eraseToAnyPublisher()
    }
    
    
    public private(set) var isAuthenticated: Bool = false {
        didSet {
            isAuthenticatedSubject.send(isAuthenticated)
        }
    }
    
    @Published private var authState: AuthManagerState = .unauthenticated {
        didSet {
            guard case .authenticated = authState else {
                isAuthenticated = false
                return
            }
            isAuthenticated = true
        }
    }
    
    public var canAuthenticateWithBiometrics: Bool {
        
        return availableBiometric == .faceID || availableBiometric == .touchID
    }
    
    private var isAuthenticatedSubject: PassthroughSubject<Bool, Never> = .init()
    

    private var appStateCancellables = Set<AnyCancellable>()
    private var generalCancellables = Set<AnyCancellable>()
    private var settingsManager: SettingsManager
    
    public init(settingsManager: SettingsManager) {
        self.settingsManager = settingsManager
        setupNotificationObservers()
    }
    

    public func deauthorize() {
        authState = .unauthenticated
    }
    


    public func waitForAuthResponse() async -> AuthManagerState {
        await waitForAuthResponse(delay: AppConstants.authenticationTimeout)
    }
    
    func waitForAuthResponse(delay: RunLoop.SchedulerTimeType.Stride) async -> AuthManagerState  {
        return await withCheckedContinuation({ continuation in
            if case .authenticated(_) = authState {
                continuation.resume(returning: authState)
            } else {
                Publishers.MergeMany(
                    Just(AuthManagerState.unauthenticated)
                        .delay(for: delay, scheduler: RunLoop.main).eraseToAnyPublisher(),
                    $authState.dropFirst().eraseToAnyPublisher()
                )
                    .first()
                    .sink { value in
                        continuation.resume(returning: value)
                    }
                    .store(in: &generalCancellables)
            }
            
        })
    }
    
    public func authorize(with password: String, using keyManager: KeyManager) throws {
        let newState: AuthManagerState
        do {
            let check = try keyManager.checkPassword(password)
            if check {
                newState = .authenticated(with: .password)
            } else {
                newState = .unauthenticated
            }
        } catch let keyManagerError as KeyManagerError {
            if keyManagerError == .invalidPassword {
                throw AuthManagerError.passwordIncorrect
            } else {
                throw keyManagerError
            }
        } catch {
            throw error
        }
        authState = newState
    }
    
    @discardableResult public func evaluateWithBiometrics() async throws -> Bool {

        guard let method = availableBiometric else {
            throw AuthManagerError.biometricsNotAvailable
        }

        defer {
            setupNotificationObservers()
        }

        do {
            debugPrint("Attempting LA auth")
            cancelNotificationObservers()
            let result = try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: L10n.keepYourEncryptedDataSafeByUsing(method.nameForMethod))
            // Successful auth - invalidate context to get fresh one next time
            // (LAContext should not be reused after successful evaluation)
            invalidateContext()
            return result
        } catch let localAuthError as LAError {
            debugPrint("LAError", localAuthError)
            
            // Invalidate context on errors that may leave it in a bad state
            switch localAuthError.code {
            case .invalidContext, .systemCancel:
                // These errors indicate the context is no longer valid
                invalidateContext()
            default:
                break
            }
            
            switch localAuthError.code {
            case .appCancel:
                break
            
            case .authenticationFailed,
                    .invalidContext,
                    .systemCancel,
                    .notInteractive:
                throw AuthManagerError.biometricsFailed
            case .userCancel, .userFallback, .passcodeNotSet:
                throw AuthManagerError.userCancelledBiometrics
                
            default:
                throw AuthManagerError.biometricsFailed
            }
        } catch {
            // Unknown error - invalidate context to be safe
            invalidateContext()
            throw AuthManagerError.biometricsFailed
        }
        return false
    }
    
    public func authorizeWithBiometrics() async throws {
        guard let method = availableBiometric else {
            throw AuthManagerError.biometricsNotAvailable
        }
        
        // Debounce: Don't trigger if we just triggered within the debounce interval
        // This prevents duplicate triggers from multiple sources firing simultaneously
        if let lastAttempt = lastBiometricAttemptTime,
           Date().timeIntervalSince(lastAttempt) < biometricDebounceInterval {
            debugPrint("Skipping duplicate biometric attempt - debounced")
            return
        }
        
        // If biometric auth is already in progress, don't start another
        guard !isBiometricAuthInProgress else {
            debugPrint("Skipping biometric attempt - already in progress")
            return
        }
        
        lastBiometricAttemptTime = Date()
        isBiometricAuthInProgress = true
        
        defer {
            isBiometricAuthInProgress = false
        }
        
        let result = try await evaluateWithBiometrics()
        if result == true {
            self.authState = .authenticated(with: method)
        } else {
            self.authState = .unauthenticated
        }
    }
}

private extension DeviceAuthManager {
    
    func loadAuthenticationPolicy() -> AuthenticationPolicy {
        guard let settings = try? settingsManager.loadSettings() else {
            return AuthenticationPolicy.defaultPolicy
        }
        let preferredAuth: AuthenticationMethod = settings.useBiometricsForAuth ?? false ? availableBiometric ?? .password : .password
        return AuthenticationPolicy(preferredAuthenticationMethod: preferredAuth, authenticationExpirySeconds: 60)
    }
    
    func reauthorizeForPassword() {
        authState = .unauthenticated
    }
    
    func cancelNotificationObservers() {
        appStateCancellables.forEach({$0.cancel()})
    }
    
    func setupNotificationObservers() {
        NotificationUtils.didEnterBackgroundPublisher
            .sink { _ in
                // Invalidate cached LAContext when going to background
                // This ensures fresh context on next foreground, avoiding stale state
                self.invalidateContext()
                self.deauthorize()
            }.store(in: &appStateCancellables)
    }
    
}
