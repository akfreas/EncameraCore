import Foundation

public enum AuthenticationMethodType: String, CaseIterable {
    case faceID = "Face ID only"
    case pinCode = "PIN Code"
    case password = "Password"
    
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