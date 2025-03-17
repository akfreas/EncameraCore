import Foundation

public enum AuthenticationMethodType: String, CaseIterable {
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
} 
