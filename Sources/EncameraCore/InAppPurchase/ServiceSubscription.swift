//
//  Subscription.swift
//  Encamera
//
//  Created by Alexander Freas on 31.10.22.
//

import Foundation
import StoreKit

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
