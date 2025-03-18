import Foundation



public enum PasscodeType: CaseIterable, Codable, Equatable, Identifiable {
    public enum PasscodeLength: Int, Codable {
        case four = 4
        case six = 6
    }   
    public static var allCases: [PasscodeType] = [.none, .pinCode(length: .four), .pinCode(length: .six), .password]

    case pinCode(length: PasscodeLength)
    case password
    case none
    
    public var id: String {
        switch self {
        case .pinCode(let length):
            return "pinCode-\(length.rawValue)"
        case .password:
            return "password"
        case .none:
            return "none"
        }
    }

    public var textDescription: String {
        switch self {
        case .pinCode(let length):
            switch length {
            case .four:
                return L10n.AuthenticationMethod.TextDescription.pinCode4Digit
            case .six:
                return L10n.AuthenticationMethod.TextDescription.pinCode6Digit
            }
        case .password:
            return L10n.AuthenticationMethod.TextDescription.password
        case .none:
            return L10n.none
        }
    }
    
    public static func == (lhs: PasscodeType, rhs: PasscodeType) -> Bool {
        switch (lhs, rhs) {
        case (.pinCode(let length1), .pinCode(let length2)):
            return length1 == length2
        case (.password, .password):
            return true
        case (.none, .none):
            return true
        default:
            return false
        }
    }
    
    private enum CodingKeys: String, CodingKey {
        case type
        case length
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        
        switch self {
        case .pinCode(let length):
            try container.encode("pinCode", forKey: .type)
            try container.encode(length.rawValue, forKey: .length)
        case .password:
            try container.encode("password", forKey: .type)
        case .none:
            try container.encode("none", forKey: .type)
        }
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        
        switch type {
        case "pinCode":
            let lengthValue = try container.decode(Int.self, forKey: .length)
            if let length = PasscodeLength(rawValue: lengthValue) {
                self = .pinCode(length: length)
            } else {
                throw DecodingError.dataCorruptedError(forKey: .length, in: container, debugDescription: "Invalid passcode length")
            }
        case "password":
            self = .password
        case "none":
            self = .none
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Invalid passcode type")
        }
    }
}
