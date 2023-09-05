//
//  StoreActor.swift
//  Encamera
//
//  Created by Alexander Freas on 31.10.22.
//

import Foundation
import StoreKit

@globalActor public actor StoreActor {
    static public let unlimitedMonthlyID = "subscription.monthly.unlimitedkeysandphotos"
    static public let unlimitedYearlyID = "subscription.yearly.unlimitedkeysandphotos"
    static public let lifetimeUnlimitedBasic = "purchase.lifetimeunlimitedbasic"
    static public let lifetimeUnlimitedBasicFamily = "purchase.lifetimeunlimitedbasicfamily"
    
    public static let subscriptionIDs: Array<String> = [
        unlimitedYearlyID,
        unlimitedMonthlyID
    ]
    
    public static let productIDs: Array<String> = [
        lifetimeUnlimitedBasic,
        lifetimeUnlimitedBasicFamily
    ]
    
    public static let allProductIDs: Array<String> = {
        return subscriptionIDs + productIDs
    }()
    
    public static let shared = StoreActor()
    
    private var loadedProducts: [String: Product] = [:]
    private var lastLoadError: Error?
    private var productLoadingTask: Task<Void, Never>?
    
    private var transactionUpdatesTask: Task<Void, Never>?
    private var statusUpdatesTask: Task<Void, Never>?
    private var storefrontUpdatesTask: Task<Void, Never>?
    private var paymentQueue = SKPaymentQueue()

    public nonisolated let subscriptionController: StoreSubscriptionController
    public nonisolated let productController: StoreProductController
    
    init() {
        self.subscriptionController = StoreSubscriptionController(productIDs: Self.subscriptionIDs)
        self.productController = StoreProductController(productIDs: Self.productIDs)
        Task(priority: .background) {
            await self.setupListenerTasksIfNecessary()
            await self.loadProducts()
        }
    }
    
    func product(identifiedBy productID: String) async -> Product? {
        await waitUntilProductsLoaded()
        return loadedProducts[productID]
    }
    
    public func presentCodeRedemptionSheet() {
        if #available(iOS 16.0, *) {
            Task {
                let scenes = await UIApplication.shared.connectedScenes
                if let windowScenes = scenes.first as? UIWindowScene {
                    
                    try await AppStore.presentOfferCodeRedeemSheet(in: windowScenes)
                }
            }
        }
        else {
            paymentQueue.presentCodeRedemptionSheet()
        }
    }
    
    private func setupListenerTasksIfNecessary() {
        if transactionUpdatesTask == nil {
            transactionUpdatesTask = Task(priority: .background) {
                for await update in StoreKit.Transaction.updates {
                    await self.handle(transaction: update)
                }
            }
        }
        if statusUpdatesTask == nil {
            statusUpdatesTask = Task(priority: .background) {
                for await update in Product.SubscriptionInfo.Status.updates {
                    await subscriptionController.handle(update: update)
                }
            }
        }
        if storefrontUpdatesTask == nil {
            storefrontUpdatesTask = Task(priority: .background) {
                for await update in Storefront.updates {
                    self.handle(storefrontUpdate: update)
                }
            }
        }
    }
    
    private func waitUntilProductsLoaded() async {
        if let task = productLoadingTask {
            await task.value
        }
        // You load all the products at once, so you can skip this if the
        // dictionary is empty.
        else if loadedProducts.isEmpty {
            let newTask = Task {
                await loadProducts()
            }
            productLoadingTask = newTask
            await newTask.value
        }
    }
    
    private func loadProducts() async {
        do {
            let products = try await Product.products(for: Self.allProductIDs)
            try Task.checkCancellation()
            loadedProducts = products.reduce(into: [:]) {
                $0[$1.id] = $1
            }
            
            Task(priority: .utility) { @MainActor in
                self.subscriptionController.subscriptions = products.compactMap({ ServiceSubscription(subscription: $0) }).sorted { product1, product2 in
                    if product1.id.contains("yearly") {
                        return true
                    } else {
                        return false
                    }
                }
                await self.subscriptionController.updateEntitlement()

                self.productController.products = products
                    .compactMap({ OneTimePurchase(product: $0) })
                await self.productController.updateEntitlement()
            }
        } catch {
            print("Failed to get in-app products: \(error)")
            lastLoadError = error
        }
        productLoadingTask = nil
    }
    
    private func handle(transaction: VerificationResult<StoreKit.Transaction>) async {
        guard case .verified(let transaction) = transaction else {
            print("Received unverified transaction: \(transaction)")
            return
        }
        // If you have a subscription, call checkEntitlement() which gets the
        // full status instead.
        if transaction.productType == .autoRenewable {
            await subscriptionController.updateEntitlement()
        }
        else if transaction.productID == Self.lifetimeUnlimitedBasic {
            await productController.set(isEntitled: !transaction.isRevoked)
        }
        await transaction.finish()
    }
    
    private func handle(storefrontUpdate newStorefront: Storefront) {
        print("Storefront changed to \(newStorefront)")
        // Cancel existing loading task if necessary.
        if let task = productLoadingTask {
            task.cancel()
        }
        // Load products again.
        productLoadingTask = Task(priority: .utility) {
            await self.loadProducts()
        }
    }
    
}

extension StoreKit.Transaction {
    var isRevoked: Bool {
        // The revocation date is never in the future.
        revocationDate != nil
    }
}
