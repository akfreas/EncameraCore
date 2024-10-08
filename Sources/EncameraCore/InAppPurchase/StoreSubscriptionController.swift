//
//  StoreSubscriptionController.swift
//  Encamera
//
//  Created by Alexander Freas on 31.10.22.
//

import Foundation
import StoreKit
import Combine

@MainActor
public final class StoreSubscriptionController: ObservableObject {
    @Published public var subscriptions: [ServiceSubscription] = []
    @Published private(set) public var entitledSubscriptionID: String?
    @Published private(set) public var autoRenewPreference: String?
    @Published private(set) public var purchaseError: (any LocalizedError)?
    @Published private(set) public var expirationDate: Date?
    
    private let productIDs: [String]
    
    private var groupID: String? {
        subscriptions.first?.subscriptionGroupID
    }
    
    public var entitledSubscription: ServiceSubscription? {
        subscriptions.first { $0.id == entitledSubscriptionID }
    }
    
    var nextSubscription: ServiceSubscription? {
        subscriptions.first { $0.id == autoRenewPreference }
    }
    private var cancellables = Set<AnyCancellable>()

    internal nonisolated init(productIDs: [String]) {
        self.productIDs = productIDs
        Task { @MainActor in
            await self.updateEntitlement()
            
        }
        
        
    }
    
    
    public func purchase(option subscription: ServiceSubscription) async -> PurchaseFinishedAction {
        let action: PurchaseFinishedAction
        do {
            let result = try await subscription.product.purchase()
            switch result {
            case .success(let verificationResult):
                let transaction = try verificationResult.payloadValue
                entitledSubscriptionID = transaction.productID
                autoRenewPreference = transaction.productID
                expirationDate = transaction.expirationDate
                await transaction.finish()
                action = .purchaseComplete(amount: subscription.product.price, currencyCode: subscription.product.priceFormatStyle.currencyCode)
            case .pending:
                print("Purchase pending user action")
                action = .pending
            case .userCancelled:
                print("User cancelled purchase")
                action = .cancelled
            @unknown default:
                print("Unknown result: \(result)")
                action = .noAction
            }
        } catch let error as LocalizedError {
            purchaseError = error
            action = .displayError
        } catch {
            print("Purchase failed: \(error)")
            action = .noAction
        }
        // Check status again.
        await updateEntitlement()
        return action
    }
    
    internal func handle(update status: Product.SubscriptionInfo.Status) {
        guard case .verified(let transaction) = status.transaction,
              case .verified(let renewalInfo) = status.renewalInfo else {
            print("""
            Unverified entitlement for \
            \(status.transaction.unsafePayloadValue.productID)
            """)
            return
        }
        if status.state == .subscribed || status.state == .inGracePeriod {
            entitledSubscriptionID = renewalInfo.currentProductID
            autoRenewPreference = renewalInfo.autoRenewPreference
            expirationDate = transaction.expirationDate
        } else {
            entitledSubscriptionID = nil
            autoRenewPreference = renewalInfo.autoRenewPreference
        }
    }
    
    internal func updateEntitlement() async {
        // Start with nil.
        entitledSubscriptionID = nil
        if let groupID = groupID {
            await updateEntitlement(groupID: groupID)
        } else {
            await updateEntitlementWithProductIDs()
        }
    }
    
    /// Update the entitlement state based on the status API.
    /// - Parameter groupID: The groupID to check status for.
    func updateEntitlement(groupID: String) async {
        guard let statuses = try? await Product.SubscriptionInfo.status(for: groupID) else {
            return
        }
        for status in statuses {
            guard case .verified(let transaction) = status.transaction,
                  case .verified(let renewalInfo) = status.renewalInfo else {
                print("""
                Unverified entitlement for \
                \(status.transaction.unsafePayloadValue.productID)
                """)
                continue
            }

            if status.state == .subscribed || status.state == .inGracePeriod {
                entitledSubscriptionID = renewalInfo.currentProductID
                autoRenewPreference = renewalInfo.autoRenewPreference
                expirationDate = transaction.expirationDate
            }
        }
    }
    
    /// Update the entitlement based on the current entitlement API. Use this if there is no network
    /// connection and the subscription group ID is not accessible.
    private func updateEntitlementWithProductIDs() async {
        for productID in productIDs {
            guard let entitlement = await StoreKit.Transaction.currentEntitlement(for: productID) else {
                continue
            }
            guard case .verified(let transaction) = entitlement else {
                print("""
                Unverified entitlement for \
                \(entitlement.unsafePayloadValue.productID)
                """)
                continue
            }
            entitledSubscriptionID = transaction.productID
            break
        }
    }
    
}
