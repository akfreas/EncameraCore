//
//  StoreEnums.swift
//  Encamera
//
//  Created by Alexander Freas on 21.11.22.
//

import Foundation

public enum PurchaseFinishedAction {
    case purchaseComplete(amount: Decimal, currencyCode: String)
    case noAction
    case displayError
}
