//
//  Strings+Manual.swift
//  EncameraCore
//
//  Created by Alexander Freas on 26.04.23.
//

import Foundation

private final class BundleToken {
  static let bundle: Bundle = {
    #if SWIFT_PACKAGE
    return Bundle.module
    #else
    return Bundle(for: BundleToken.self)
    #endif
  }()
}

extension L10n {
    private static func tr(_ table: String, _ key: String, _ args: CVarArg..., fallback value: String) -> String {
      let format = BundleToken.bundle.localizedString(forKey: key, value: value, table: table)
      return String(format: format, locale: Locale.current, arguments: args)
    }

    public static func imageS(_ p1: Int) -> String {
      return L10n.tr("Localizable", "%@ image(s)", p1, fallback: "%@ image(s)")
    }
}
