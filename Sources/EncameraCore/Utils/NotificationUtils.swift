//
//  NotificationUtils.swift
//  Encamera
//
//  Created by Alexander Freas on 05.08.22.
//

import Foundation
import UIKit
import Combine

public struct NotificationUtils {
    
    private static var noOp = false
    
    enum Keys {
        static var hardwareButtonPressedKey = "hardwareButtonPressedKey"
    }
    
    public static func sendHardwareButtonPressed() {
        NotificationCenter.default.post(name: Notification.Name(Keys.hardwareButtonPressedKey), object: "pressed")
    }
    
    public static var hardwareButtonPressedPublisher: AnyPublisher<Notification, Never> {
        return publisher(for: Notification.Name(Keys.hardwareButtonPressedKey))
    }
    
    public static var didBecomeActivePublisher: AnyPublisher<Notification, Never> {
        
        return publisher(for: UIApplication.didBecomeActiveNotification)
    }
    
    public static var didEnterBackgroundPublisher: AnyPublisher<Notification, Never> {
        return publisher(for: UIApplication.didEnterBackgroundNotification)
    }
    
    public static var willResignActivePublisher: AnyPublisher<Notification, Never> {
        return publisher(for: UIApplication.willResignActiveNotification)
    }
    
    
    public static var didFinishLaunchingPublisher: AnyPublisher<Notification, Never> {
        return publisher(for: UIApplication.didFinishLaunchingNotification)
    }
    
    public static var orientationDidChangePublisher: AnyPublisher<Notification, Never> {
        return publisher(for: UIDevice.orientationDidChangeNotification)
    }
    
    public static var systemClockDidChangePublisher: AnyPublisher<Notification, Never> {
        return publisher(for: .NSSystemClockDidChange)
    }
    
    private static func publisher(for notifType: Notification.Name) -> AnyPublisher<Notification, Never> {
        guard noOp == false else {
            return PassthroughSubject().eraseToAnyPublisher()
        }
        return NotificationCenter.default
            .publisher(for: notifType)
            .eraseToAnyPublisher()
    }
}
