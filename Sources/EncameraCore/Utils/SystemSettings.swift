//
//  File.swift
//  EncameraCore
//
//  Created by Alexander Freas on 15.10.24.
//

import Foundation
import UIKit

public struct SystemSettings {

    public static func openNotificationSettings() {
        guard let url = URL(string: UIApplication.openNotificationSettingsURLString) else {
            return
        }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }

    public static func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else {
            return
        }
        UIApplication.shared.open(url)
    }

}
