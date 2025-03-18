//
//  PasswordValidator.swift
//  Encamera
//
//  Created by Alexander Freas on 15.07.22.
//

import Foundation


public enum PasswordValidation {
    case notDetermined
    case valid
    case invalidTooShort
    case invalidDifferent
    case invalidTooLong

    public var validationDescription: String {
        switch self {
        case .notDetermined:
            return L10n.notDetermined
        case .valid:
            return L10n.passwordIsValid
        case .invalidTooShort:
            return L10n.passwordIsTooShort(PasswordValidation.minPasswordLength)
        case .invalidDifferent:
            return L10n.passwordsDoNotMatch
        case .invalidTooLong:
            return L10n.passwordIsTooLong(PasswordValidation.maxPasswordLength)

        }
    }

    static public let minPasswordLength = 4
    static public let maxPasswordLength = 50
}

public struct PasswordValidator {

    public init() {}
    public static func validate(password: String, type: PasscodeType) -> PasswordValidation {
        let validationState: PasswordValidation
        switch (type, password) {
        case (.pinCode(length: let length), password) where password.count > length.rawValue:
            validationState = .invalidTooLong
        case (.pinCode(length: let length), password) where password.count < length.rawValue:
            validationState = .invalidTooShort
        case (.pinCode(length: let length), password) where password.count == length.rawValue:
            validationState = .valid
        case (.password, password) where password.count > PasswordValidation.maxPasswordLength:
            validationState = .invalidTooLong
        case (.password, password) where password.count < PasswordValidation.minPasswordLength:
            validationState = .invalidTooShort
        case (.password, _):
            validationState = .valid
        case (.pinCode(length: let length), _):
            validationState = .notDetermined
        case (.none, _):
            validationState = .notDetermined
        }
        return validationState

    }

    public static func validatePasswordPair(_ password1: String, password2: String, type: PasscodeType) -> PasswordValidation {
        let validationState: PasswordValidation
        switch (password1, password2) {
        case (password2, password1):
            return validate(password: password1, type: type)
        default:
            validationState = .invalidDifferent
        }
        return validationState
    }
}
