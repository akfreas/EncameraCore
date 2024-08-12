import Foundation
import StoreKit

public protocol Purchasable: Identifiable, Equatable {
    init?(product: Product, savings: SubscriptionSavings?)
    var product: Product { get }
    var id: String { get }
    var priceText: String { get }
    var purchaseActionText: String { get }
    var displayName: String { get }
    var productDescription: String? { get }
    var savings: SubscriptionSavings? { get }
}
