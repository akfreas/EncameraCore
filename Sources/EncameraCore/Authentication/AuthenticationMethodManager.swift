import Foundation
import Combine

/// A utility class that manages all interactions with the authentication method type in UserDefaults.
/// This centralizes the logic and ensures that direct references to `.authenticationMethodType` only exist in this class.
public class AuthenticationMethodManager {
    
    // MARK: - Properties
    
    /// Publisher that emits when the authentication method changes
    public static var authenticationMethodPublisher: AnyPublisher<AuthenticationMethodType, Never> {
        UserDefaultUtils.publisher(for: .authenticationMethodType)
            .map { value -> AuthenticationMethodType in
                guard let stringValue = value as? String else {
                    return .pinCode
                }
                return AuthenticationMethodType(rawValue: stringValue) ?? .pinCode
            }
            .eraseToAnyPublisher()
    }
    
    // MARK: - Public Methods
    
    /// Get the current authentication method type
    /// - Returns: The current authentication method type, defaulting to .pinCode if not set
    public static func getCurrentAuthenticationMethod() -> AuthenticationMethodType {
        guard let method = UserDefaultUtils.string(forKey: .authenticationMethodType) else {
            return .pinCode
        }
        return AuthenticationMethodType(rawValue: method) ?? .pinCode
    }
    
    /// Set the authentication method type
    /// - Parameter method: The authentication method type to set
    public static func setAuthenticationMethod(_ method: AuthenticationMethodType) {
        UserDefaultUtils.set(method.rawValue, forKey: .authenticationMethodType)
    }
    
    /// Reset the authentication method to the default (.pinCode)
    public static func resetToDefault() {
        setAuthenticationMethod(.pinCode)
    }
} 