//
//  StorePurchaseController.swift
//  Encamera
//
//  Created by Alexander Freas on 19.11.22.
//

import Foundation
import StoreKit
import Combine

@MainActor
public final class StoreProductController: ObservableObject {
    @Published public var products: [OneTimePurchase] = []
    @Published public var purchasedProduct: OneTimePurchase?
    @Published private(set) public var isEntitled: Bool = false
    @Published private(set) var purchaseError: (any LocalizedError)?
    
    private let productIDs: [String]
    
    internal nonisolated init(productIDs: [String]) {
        self.productIDs = productIDs
        Task(priority: .background) {
            await self.updateEntitlement()
        }
    }
    
    public func purchase(product: OneTimePurchase) async -> PurchaseFinishedAction {
        let action: PurchaseFinishedAction
        
        do {
            let result = try await product.product.purchase()
            switch result {
            case .success(let verificationResult):
                let transaction = try verificationResult.payloadValue
                self.isEntitled = true
                await transaction.finish()
            case .pending:
                print("Purchase pending user action")
            case .userCancelled:
                print("User cancelled purchase")
            @unknown default:
                print("Unknown result: \(result)")
            }
            action = .noAction
        } catch let error as LocalizedError {
            purchaseError = error
            action = .displayError
        } catch {
            print("Purchase failed: \(error)")
            action = .noAction
        }
        await updateEntitlement()
        return action

    }
    
    internal func set(isEntitled: Bool) {
        self.isEntitled = isEntitled
    }
    
    func updateEntitlement() async {
        var purchased: [OneTimePurchase] = []
        for productID in productIDs {
            let entitlementForProduct = await StoreKit.Transaction.currentEntitlement(for: productID)

            guard case .verified(let transaction) = entitlementForProduct else {
                continue
            }
            purchased += products.filter({$0.product.id == transaction.productID})
        }
        purchasedProduct = purchased.first
        isEntitled = purchasedProduct != nil
    }
}
