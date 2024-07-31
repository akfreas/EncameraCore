//  Created by Alexander Freas on 31.07.24.
//

import Foundation


public class DemoPurchasedPermissionManaging: PurchasedPermissionManaging {

    public init() {}
    func requestProducts() async {

    }

    public func isAllowedAccess(feature: AppFeature) -> Bool {
        return false
    }

    func beginPurchase(for feature: EncameraSubscription) async {

    }
    public func hasEntitlement() -> Bool {
        return false
    }
}
