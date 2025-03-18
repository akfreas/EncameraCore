import Foundation

public enum PasscodeType: CaseIterable, Codable {
    public static var allCases: [AuthenticationMethodType = [.pinCode(length: 4), .pinCode(length: 6), .password]

    case pinCode(length: Int)
    case password

    public var textDescription: String {
        switch self {
        case .pinCode(let length):
            if length == 4 {
                return L10n.AuthenticationMethod.TextDescription.pinCode4Digit
            } else if length == 6 {
                return L10n.AuthenticationMethod.TextDescription.pinCode6Digit
            }
        case .password:
            return L10n.AuthenticationMethod.TextDescription.password
        }
    }
} 
