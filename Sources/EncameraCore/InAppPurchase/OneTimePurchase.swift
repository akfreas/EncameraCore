import Foundation
import StoreKit

@dynamicMemberLookup
public struct OneTimePurchase: Identifiable, Equatable {
    public let product: Product
   
    public var id: String { product.id }
    
    public init?(product: Product) {
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

