import Foundation
import StoreKit

@dynamicMemberLookup
public struct OneTimePurchase: Purchasable {
    
    public var displayName: String {
        product.displayName
    }

    public var savings: SubscriptionSavings?
    
    public var productDescription: String? {
        L10n.buyOnceUseForever
    }
    public var purchaseActionText: String = L10n.purchaseProduct

    public let product: Product
   
    public var id: String { product.id }
    
    public init?(product: Product, savings: SubscriptionSavings? = nil) {
        guard product.subscription == nil else {
            return nil
        }
        self.product = product
    }
    
    public subscript<T>(dynamicMember keyPath: KeyPath<Product, T>) -> T {
        product[keyPath: keyPath]
    }
    
    public var priceText: String {
        "\(self.displayPrice)"
    }
}

