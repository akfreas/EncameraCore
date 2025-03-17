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
}

public protocol AuthManager {
    var isAuthenticatedPublisher: AnyPublisher<Bool, Never> { get }
    var isAuthenticated: Bool { get }
    var availableBiometric: AuthenticationMethod? { get }
    var useBiometricsForAuth: Bool { get set }
    var canAuthenticateWithBiometrics: Bool { get }
    var deviceBiometryType: AuthenticationMethod? { get }
    
    // Authentication methods
    func deauthorize()
    func authorize(with password: String, using keyManager: KeyManager) throws
    func authorizeWithBiometrics() async throws
    @discardableResult func evaluateWithBiometrics() async throws -> Bool
    func waitForAuthResponse() async -> AuthManagerState
    
    // Authentication method management
    var authenticationMethodsPublisher: AnyPublisher<[AuthenticationMethodType], Never> { get }
    func getAuthenticationMethods() -> [AuthenticationMethodType]
    func getUserInputAuthenticationMethod() -> AuthenticationMethodType
    func hasBiometricAuthenticationMethod() -> Bool
    func hasAuthenticationMethod(_ method: AuthenticationMethodType) -> Bool
    @discardableResult func addAuthenticationMethod(_ method: AuthenticationMethodType) -> Bool
    func removeAuthenticationMethod(_ method: AuthenticationMethodType)
    func setAuthenticationMethod(_ method: AuthenticationMethodType)
    func resetAuthenticationMethodsToDefault()
}

public class DeviceAuthManager: AuthManager {
    
    var context: LAContext {
        let context = LAContext()
        context.localizedCancelTitle = L10n.cancel
        return context
    }
    
    var _availableBiometric: AuthenticationMethod?
    public var availableBiometric: AuthenticationMethod? {
        if let _availableBiometric = _availableBiometric {
            return _availableBiometric
        }
        
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else {
            return .none
        }
        _availableBiometric = deviceBiometryType
        return _availableBiometric
    }

    public var deviceBiometryType: AuthenticationMethod? {
        AuthenticationMethod.methodFrom(biometryType: context.biometryType)
    }

    var _useBiometricsForAuth: Bool?
    public var useBiometricsForAuth: Bool {
        get {
            if let _useBiometricsForAuth = self._useBiometricsForAuth {
                return _useBiometricsForAuth
            }
            
            // Check if FaceID is enabled as an authentication method
            let faceIDEnabled = hasBiometricAuthenticationMethod()
            
            // If FaceID is enabled as an authentication method, check the settings
            if faceIDEnabled {
                guard let settings = try? settingsManager.loadSettings(),
                      let useBiometrics = settings.useBiometricsForAuth, availableBiometric != .none else {
                    return false
                }
                self._useBiometricsForAuth = useBiometrics
                return useBiometrics
            }
            
            // If FaceID is not enabled as an authentication method, return false
            return false
        }
        set(value) {
            self._useBiometricsForAuth = value
            try? settingsManager.saveSettings(SavedSettings(useBiometricsForAuth: value))
            
            // If biometrics are enabled, make sure FaceID is added as an authentication method
            if value && availableBiometric != .none {
                _ = addAuthenticationMethod(.faceID)
            } else if !value {
                // If biometrics are disabled, make sure FaceID is removed as an authentication method
                removeAuthenticationMethod(.faceID)
            }
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
        // Check if biometrics are available on the device AND if FaceID is enabled as an authentication method
        let biometricsAvailable = availableBiometric == .faceID || availableBiometric == .touchID
        let faceIDEnabled = hasBiometricAuthenticationMethod()
        
        // If keyManager is not set yet, just check if biometrics are available and enabled
        guard let keyManager = self.keyManager else {
            return biometricsAvailable && faceIDEnabled
        }
        
        return biometricsAvailable && (faceIDEnabled || !keyManager.passwordExists())
    }
    
    private var isAuthenticatedSubject: PassthroughSubject<Bool, Never> = .init()
    

    private var appStateCancellables = Set<AnyCancellable>()
    private var generalCancellables = Set<AnyCancellable>()
    private var settingsManager: SettingsManager
    private var _keyManager: KeyManager?
    
    // Property to access keyManager, with a fallback for when it's not set yet
    private var keyManager: KeyManager? {
        return _keyManager
    }
    
    // Method to set the keyManager after initialization
    public func setKeyManager(_ keyManager: KeyManager) {
        self._keyManager = keyManager
    }
    
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
            return result
        } catch let localAuthError as LAError {
            debugPrint("LAError", localAuthError)
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
            throw AuthManagerError.biometricsFailed
        }
        return false
    }
    
    public func authorizeWithBiometrics() async throws {
        guard let method = availableBiometric else {
            throw AuthManagerError.biometricsNotAvailable
        }
        let result = try await evaluateWithBiometrics()
        if result == true {
            self.authState = .authenticated(with: method)
        } else {
            self.authState = .unauthenticated
        }
    }
    
    // MARK: - Authentication Method Management
    
    public var authenticationMethodsPublisher: AnyPublisher<[AuthenticationMethodType], Never> {
        UserDefaultUtils.publisher(for: .authenticationMethods)
            .map { value -> [AuthenticationMethodType] in
                guard let data = value as? Data,
                      let methods = try? JSONDecoder().decode([AuthenticationMethodType].self, from: data) else {
                    return [.pinCode]
                }
                return methods
            }
            .eraseToAnyPublisher()
    }
    
    public static func getAuthenticationMethods() -> [AuthenticationMethodType] {
        guard let data = UserDefaultUtils.data(forKey: .authenticationMethods),
              let methods = try? JSONDecoder().decode([AuthenticationMethodType].self, from: data) else {
            return [.pinCode]
        }
        return methods
    }

    public func getAuthenticationMethods() -> [AuthenticationMethodType] {
        return Self.getAuthenticationMethods()
    }

    public func getUserInputAuthenticationMethod() -> AuthenticationMethodType {
        return Self.getUserInputAuthenticationMethod()
    }

    public static func getUserInputAuthenticationMethod() -> AuthenticationMethodType {
        let methods = getAuthenticationMethods()

        // First check for password
        if methods.contains(.password) {
            return .password
        }

        // Then check for PIN code
        if methods.contains(.pinCode) {
            return .pinCode
        }

        // Default to PIN code if neither is found
        return .pinCode
    }
    
    public func hasBiometricAuthenticationMethod() -> Bool {
        return getAuthenticationMethods().contains(.faceID)
    }
    
    public func hasAuthenticationMethod(_ method: AuthenticationMethodType) -> Bool {
        return getAuthenticationMethods().contains(method)
    }
    
    @discardableResult
    public func addAuthenticationMethod(_ method: AuthenticationMethodType) -> Bool {
        var methods = getAuthenticationMethods()

        methods.removeAll(where: {$0.isIncompatibleWith(method)})

        // Use a Set to avoid duplicates
        var methodsSet = Set(methods)
        methodsSet.insert(method)
        methods = Array(methodsSet)

        // Save the updated methods
        if let data = try? JSONEncoder().encode(methods) {
            UserDefaultUtils.set(data, forKey: .authenticationMethods)
            
            // Update biometrics settings if FaceID is added, but avoid circular dependency
            if method == .faceID {
                self._useBiometricsForAuth = true
                try? settingsManager.saveSettings(SavedSettings(useBiometricsForAuth: true))
            }
        }

        return true
    }
    
    public func removeAuthenticationMethod(_ method: AuthenticationMethodType) {
        var methods = getAuthenticationMethods()
        methods.removeAll { $0 == method }

        // If all methods were removed, add the default
        if methods.isEmpty {
            methods = [.pinCode]
        }

        // Save the updated methods
        if let data = try? JSONEncoder().encode(methods) {
            UserDefaultUtils.set(data, forKey: .authenticationMethods)
            
            // Update biometrics settings if FaceID is removed, but avoid circular dependency
            if method == .faceID {
                self._useBiometricsForAuth = false
                try? settingsManager.saveSettings(SavedSettings(useBiometricsForAuth: false))
            }
        }
    }
    
    public func setAuthenticationMethod(_ method: AuthenticationMethodType) {
        let methods = [method]
        if let data = try? JSONEncoder().encode(methods) {
            UserDefaultUtils.set(data, forKey: .authenticationMethods)
            
            // Update biometrics settings based on whether FaceID is included, but avoid circular dependency
            self._useBiometricsForAuth = method == .faceID
            try? settingsManager.saveSettings(SavedSettings(useBiometricsForAuth: method == .faceID))
        }
    }
    
    public func resetAuthenticationMethodsToDefault() {
        setAuthenticationMethod(.pinCode)
        // Since we're setting to pinCode, make sure biometrics are disabled
        // This is handled in setAuthenticationMethod
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
    
    func storeAuthenticationPolicy(_ policy: AuthenticationPolicy) throws {
        let data = try JSONEncoder().encode(policy)
        UserDefaultUtils.set(data, forKey: UserDefaultKey.authenticationPolicy)
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

                self.deauthorize()
            }.store(in: &appStateCancellables)
    }
    
}
