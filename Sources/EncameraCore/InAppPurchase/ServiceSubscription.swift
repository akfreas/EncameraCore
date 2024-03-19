//
//  Subscription.swift
//  Encamera
//
//  Created by Alexander Freas on 31.10.22.
//

import Foundation
import StoreKit

@dynamicMemberLookup
public struct ServiceSubscription: Purchasable {
    public var displayName: String {
        product.displayName
    }

    public var savings: SubscriptionSavings?
    
    public var productDescription: String? {
        guard let subscription = product.subscription else {
            return nil
        }
        if subscription.subscriptionPeriod.unit == .month {
            return nil
        } else if subscription.subscriptionPeriod.unit == .year {
            return savings?.formattedMonthlyPrice
        }
        return nil
    }

    public var purchaseActionText: String = L10n.subscribe

    public let product: Product
    public var subscriptionInfo: Product.SubscriptionInfo {
        product.subscription.unsafelyUnwrapped
    }
    
    public var id: String { product.id }
    
    public init?(product: Product, savings: SubscriptionSavings? = nil) {
        guard product.subscription != nil else {
            return nil
        }
        self.savings = savings
        self.product = product
    }
    
    public subscript<T>(dynamicMember keyPath: KeyPath<Product, T>) -> T {
        product[keyPath: keyPath]
    }
    
    public subscript<T>(dynamicMember keyPath: KeyPath<Product.SubscriptionInfo, T>) -> T {
        subscriptionInfo[keyPath: keyPath]
    }
    public var priceText: String {
        "\(self.displayPrice)/\(self.subscriptionPeriod.unit.localizedDescription.lowercased())"
    }

    
}

public struct SubscriptionSavings: Equatable {
    let totalSavings: Decimal
    let monthlyPrice: Decimal
    let granularPricePeriod: Product.SubscriptionPeriod.Unit
    let priceFormatStyle: Decimal.FormatStyle.Currency
    let subscriptionPeriodUnitFormatStyle: Product.SubscriptionPeriod.Unit.FormatStyle

    public init(totalSavings: Decimal, granularPrice: Decimal, granularPricePeriod: Product.SubscriptionPeriod.Unit, priceFormatStyle: Decimal.FormatStyle.Currency, subscriptionPeriodUnitFormatStyle: Product.SubscriptionPeriod.Unit.FormatStyle) {
        self.totalSavings = totalSavings
        self.monthlyPrice = granularPrice
        self.granularPricePeriod = granularPricePeriod
        self.priceFormatStyle = priceFormatStyle
        self.subscriptionPeriodUnitFormatStyle = subscriptionPeriodUnitFormatStyle
    }

    public var formattedTotalSavings:  String {
        return L10n.saveAmount(totalSavings.formatted(priceFormatStyle))
    }
    
    public var formattedMonthlyPrice: String {
        let currency = monthlyPrice.formatted(priceFormatStyle)
        let period = granularPricePeriod.formatted(subscriptionPeriodUnitFormatStyle).lowercased()
        return "\(currency)/\(period)"
    }

    public static func == (lhs: SubscriptionSavings, rhs: SubscriptionSavings) -> Bool {
        return lhs.totalSavings == rhs.totalSavings && lhs.monthlyPrice == rhs.monthlyPrice && lhs.granularPricePeriod == rhs.granularPricePeriod
    }
}
