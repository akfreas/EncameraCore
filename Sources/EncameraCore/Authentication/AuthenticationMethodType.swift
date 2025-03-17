import Foundation

public enum AuthenticationMethodType: String, CaseIterable, Codable {
    case faceID
    case pinCode
    case password
    
    public var securityLevel: String {
        switch self {
        case .faceID:
            return "Low protection"
        case .pinCode:
            return "Moderate protection"
        case .password:
            return "Strong protection"
        }
    }
    
    /// Checks if this authentication method is incompatible with another method
    /// - Parameter otherMethod: The other authentication method to check against
    /// - Returns: True if the methods are incompatible and cannot be used together
    public func isIncompatibleWith(_ otherMethod: AuthenticationMethodType) -> Bool {
        // Pin and password are incompatible with each other
        if self == .pinCode && otherMethod == .password {
            return true
        }
        if self == .password && otherMethod == .pinCode {
            return true
        }
        
        // Same methods are not incompatible
        return false
    }
} 
