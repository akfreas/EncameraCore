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
    static public let maxPasswordLength = 6
}

public struct PasswordValidator {

    public init() {}
    public static func validate(password: String) -> PasswordValidation {
        let validationState: PasswordValidation
        switch (password) {
        case password where password.count > PasswordValidation.maxPasswordLength:
            validationState = .invalidTooLong
        case password where password.count < PasswordValidation.minPasswordLength:
            validationState = .invalidTooShort
        default:
            validationState = .valid
        }
        return validationState

    }

    public static func validatePasswordPair(_ password1: String, password2: String) -> PasswordValidation {
        let validationState: PasswordValidation
        switch (password1, password2) {
        case (password2, password1):
            return validate(password: password1)
        default:
            validationState = .invalidDifferent
        }
        return validationState
    }
}
