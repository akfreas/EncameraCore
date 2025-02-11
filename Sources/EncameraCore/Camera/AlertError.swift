//
//  AlertError.swift
//  Encamera
//
//  Created by Alexander Freas on 04.07.22.
//

import Foundation

public struct AlertError {
    public var title: String = ""
    public var message: String = ""
    public var primaryButtonTitle = L10n.accept
    public var secondaryButtonTitle: String?
    public var primaryAction: (() -> ())?
    public var secondaryAction: (() -> ())?
    
    init(title: String = "", message: String = "", primaryButtonTitle: String = L10n.accept, secondaryButtonTitle: String? = nil, primaryAction: (() -> ())? = nil, secondaryAction: (() -> ())? = nil) {
        self.title = title
        self.message = message
        self.primaryAction = primaryAction
        self.primaryButtonTitle = primaryButtonTitle
        self.secondaryAction = secondaryAction
    }
}
