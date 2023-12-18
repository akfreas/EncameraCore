//
//  StoreKitUtils.swift
//  Encamera
//
//  Created by Alexander Freas on 12.10.22.
//

import Foundation
import StoreKit

enum RenewalFrequency: String {
    case monthly
    case yearly
    
}

enum EncameraSubscription: CaseIterable {
    static var allCases: [EncameraSubscription] = [.unlimitedPhotosAndKeys(.yearly), .unlimitedPhotosAndKeys(.monthly)]
    
    static var allProductIDs: Set<String> {
        Set(allCases.map({$0.productId}))
    }
    
    private static let unlimitedPhotosAndKeysString = "unlimitedphotosandkeys"
    
    case unlimitedPhotosAndKeys(RenewalFrequency)
    
    var productId: String {
        var frequency: RenewalFrequency
        var subscription: String
        switch self {
        case .unlimitedPhotosAndKeys(let renewalFrequency):
            subscription = Self.unlimitedPhotosAndKeysString
            frequency = renewalFrequency
        }
        return "subscription.\(frequency).\(subscription)"
    }
    
    init?(product: Product) {
        let components = product.id.components(separatedBy: ".")
        let frequencyString = components[1]
        let subscriptionString = components[2]
        
        guard let frequency = RenewalFrequency(rawValue: frequencyString), subscriptionString == Self.unlimitedPhotosAndKeysString else {
            
                return nil
        }
        self = .unlimitedPhotosAndKeys(frequency)
    }
}

extension Product {
    
    var encameraSubscription: EncameraSubscription? {
        EncameraSubscription(product: self)
    }
}

public enum AppFeature {
    case accessPhoto(count: Double)
    case createKey(count: Double)
}


public protocol PurchasedPermissionManaging {
    func isAllowedAccess(feature: AppFeature) -> Bool
    func hasEntitlement() -> Bool
}

public class AppPurchasedPermissionUtils: PurchasedPermissionManaging, ObservableObject {
    
    let subscriptionController = StoreActor.shared.subscriptionController
    let purchaseController = StoreActor.shared.productController
    public init() {
    }
    
    @MainActor
    public func isAllowedAccess(feature: AppFeature) -> Bool {
        switch feature {
        case .accessPhoto(let count) where count <= AppConstants.maxPhotoCountBeforePurchase + 1 && count > 0,
            .createKey(let count) where count < AppConstants.maxPhotoCountBeforePurchase:
            return true
        default:
            return hasEntitlement()
        }
    }
    
    @MainActor
    public func hasEntitlement() -> Bool {
        return subscriptionController.entitledSubscriptionID != nil || purchaseController.isEntitled

    }
}
