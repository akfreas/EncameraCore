//
//  Subscription.swift
//  Encamera
//
//  Created by Alexander Freas on 31.10.22.
//

import Foundation
import StoreKit

@dynamicMemberLookup
public struct ServiceSubscription: Identifiable, Equatable {
    public let product: Product
    public var subscriptionInfo: Product.SubscriptionInfo {
        product.subscription.unsafelyUnwrapped
    }
    
    public var id: String { product.id }
    
    public init?(subscription: Product) {
        guard subscription.subscription != nil else {
            return nil
        }
        self.product = subscription
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

public struct SubscriptionSavings {
    let totalSavings: Decimal
    let monthlyPrice: Decimal
    let granularPricePeriod: Product.SubscriptionPeriod.Unit
    
    public init(totalSavings: Decimal, granularPrice: Decimal, granularPricePeriod: Product.SubscriptionPeriod.Unit) {
        self.totalSavings = totalSavings
        self.monthlyPrice = granularPrice
        self.granularPricePeriod = granularPricePeriod
    }

    public func formattedTotalSavings(for subscription: ServiceSubscription) ->  String {
        return L10n.saveAmount(totalSavings.formatted(subscription.priceFormatStyle))
    }
    
    public func formattedMonthlyPrice(for subscription: ServiceSubscription) -> String {
        let currency = monthlyPrice.formatted(subscription.priceFormatStyle)
        let period = granularPricePeriod.formatted(subscription.subscriptionPeriodUnitFormatStyle).lowercased()
        return "\(currency)/\(period)"
    }
}
