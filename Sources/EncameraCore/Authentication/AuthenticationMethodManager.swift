import Foundation
import Combine

/// A utility class that manages all interactions with the authentication method types in UserDefaults.
/// This centralizes the logic and ensures that direct references to `.authenticationMethods` only exist in this class.
public class AuthenticationMethodManager {

    // MARK: - Properties

    /// Publisher that emits when the authentication methods change
    public static var authenticationMethodsPublisher: AnyPublisher<[AuthenticationMethodType], Never> {
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

    // MARK: - Public Methods

    /// Get all current authentication methods
    /// - Returns: Array of authentication methods, defaulting to [.pinCode] if not set
    public static func getAuthenticationMethods() -> [AuthenticationMethodType] {
        guard let data = UserDefaultUtils.data(forKey: .authenticationMethods),
              let methods = try? JSONDecoder().decode([AuthenticationMethodType].self, from: data) else {
            return [.pinCode]
        }
        return methods
    }

    /// Get the primary user input authentication method (PIN or password)
    /// - Returns: The user input authentication method, defaulting to .pinCode if not set
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

    /// Check if biometric authentication is enabled
    /// - Returns: True if biometric authentication is enabled
    public static func hasBiometricAuthenticationMethod() -> Bool {
        return getAuthenticationMethods().contains(.faceID)
    }

    /// Check if a specific authentication method is enabled
    /// - Parameter method: The authentication method to check for
    /// - Returns: True if the method is enabled
    public static func hasAuthenticationMethod(_ method: AuthenticationMethodType) -> Bool {
        return getAuthenticationMethods().contains(method)
    }

    /// Add an authentication method
    /// - Parameter method: The authentication method to add
    /// - Returns: True if the method was added, false if it was incompatible with existing methods
    @discardableResult
    public static func addAuthenticationMethod(_ method: AuthenticationMethodType) -> Bool {
        var methods = getAuthenticationMethods()

        methods.removeAll(where: {$0.isIncompatibleWith(method)})

        // Use a Set to avoid duplicates
        var methodsSet = Set(methods)
        methodsSet.insert(method)
        methods = Array(methodsSet)

        // Save the updated methods
        if let data = try? JSONEncoder().encode(methods) {
            UserDefaultUtils.set(data, forKey: .authenticationMethods)
        }

        return true
    }

    /// Remove an authentication method
    /// - Parameter method: The authentication method to remove
    public static func removeAuthenticationMethod(_ method: AuthenticationMethodType) {
        var methods = getAuthenticationMethods()
        methods.removeAll { $0 == method }

        // If all methods were removed, add the default
        if methods.isEmpty {
            methods = [.pinCode]
        }

        // Save the updated methods
        if let data = try? JSONEncoder().encode(methods) {
            UserDefaultUtils.set(data, forKey: .authenticationMethods)
        }
    }

    /// Set a single authentication method (removes all others)
    /// - Parameter method: The authentication method to set
    public static func setAuthenticationMethod(_ method: AuthenticationMethodType) {
        let methods = [method]
        if let data = try? JSONEncoder().encode(methods) {
            UserDefaultUtils.set(data, forKey: .authenticationMethods)
        }
    }

    /// Reset the authentication methods to the default ([.pinCode])
    public static func resetToDefault() {
        setAuthenticationMethod(.pinCode)
    }
}
