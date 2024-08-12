//  Created by Alexander Freas on 04.03.24.
//

import Foundation
import Foundation

public class LaunchCountUtils {

    private static var currentVersion: String {
        return Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
    }

    public static func recordCurrentVersionLaunch() {

        var launchCount = UserDefaultUtils.dictionary(forKey: .launchCountKey) as? [String: Int] ?? [String: Int]()
        launchCount[currentVersion] = (launchCount[currentVersion] ?? 0) + 1
        UserDefaultUtils.set(launchCount, forKey: .launchCountKey)

        UserDefaultUtils.set(currentVersion, forKey: .lastVersionKey)
    }

    public static func fetchCurrentVersionLaunchCount() -> Int {

        let launchCount = UserDefaultUtils.dictionary(forKey: .launchCountKey) as? [String: Int] ?? [String: Int]()
        debugPrint("Launch count: \(launchCount)")
        return launchCount[currentVersion] ?? 0
    }

    public static func isUpgradeLaunch() -> Bool {

        if let lastVersion = UserDefaultUtils.string(forKey: .lastVersionKey), lastVersion != currentVersion {
            return true
        }
        return false
    }
}
