//
//  File.swift
//  EncameraCore
//
//  Created by Alexander Freas on 26.11.24.
//

import Foundation
import UIKit

extension UIApplication {
    public static func topMostViewController() -> UIViewController? {
        // Get the connected scenes
        let connectedScenes = UIApplication.shared.connectedScenes

        // Find the first active UIWindowScene
        let windowScene = connectedScenes.first { $0.activationState == .foregroundActive } as? UIWindowScene

        // Get the root view controller from the key window
        if let rootViewController = windowScene?.windows.first(where: { $0.isKeyWindow })?.rootViewController {
            var currentVC = rootViewController

            // Traverse to find the topmost presented view controller
            while let presentedVC = currentVC.presentedViewController {
                currentVC = presentedVC
            }

            return currentVC
        }

        return nil
    }

}
