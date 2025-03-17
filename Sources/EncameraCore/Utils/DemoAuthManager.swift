//
//  DemoAuthManager.swift
//  Encamera
//
//  Created by Alexander Freas on 16.07.22.
//

import Foundation
import Combine

public class DemoAuthManager: AuthManager {
    public var authenticationMethodsPublisher: AnyPublisher<[AuthenticationMethodType], Never>

    public func getUserInputAuthenticationMethod() -> AuthenticationMethodType {
        return .faceID
    }
    
    public func hasBiometricAuthenticationMethod() -> Bool {
        false
    }
    
    public func hasAuthenticationMethod(_ method: AuthenticationMethodType) -> Bool {
        return false
    }
    
    public func setAuthenticationMethod(_ method: AuthenticationMethodType) {

    }
    
    public func resetAuthenticationMethodsToDefault() {

    }
    
    public func waitForAuthResponse() async -> AuthManagerState {
        return .unauthenticated
    }
    public init() {
        fatalError()
    }
    
    public var availableBiometric: AuthenticationMethod? = .faceID
    
    public var isAuthenticatedPublisher: AnyPublisher<Bool, Never> = PassthroughSubject<Bool, Never>().eraseToAnyPublisher()
    
    public var isAuthenticated: Bool = false
    
    public var canAuthenticateWithBiometrics: Bool = true

    public var deviceBiometryType: AuthenticationMethod? = .faceID

    public func deauthorize() {
        
    }

    public func evaluateWithBiometrics() async throws -> Bool {
        return false
    }
    public func authorize(with password: String, using keyManager: KeyManager) throws {
        
    }
    
    public func authorizeWithBiometrics() async throws {
        
    }
    public var useBiometricsForAuth: Bool = true
    
    public func getAuthenticationMethods() -> [AuthenticationMethodType] {
        return [.faceID, .pinCode, .password]
    }
    
    public func addAuthenticationMethod(_ method: AuthenticationMethodType) -> Bool {
        return true
    }
    
    public func removeAuthenticationMethod(_ method: AuthenticationMethodType) {

    }

    public func getAuthenticationMethodType() -> AuthenticationMethodType {
        return .faceID
    }

    public func getAuthenticationMethod() -> AuthenticationMethod {
        return .faceID
    }

}
