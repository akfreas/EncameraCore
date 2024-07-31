import Foundation
import Sodium

public class DemoPrivateKey {
    public static func dummyKey(name: String) -> PrivateKey {
        let hash: Array<UInt8> = Sodium().secretStream.xchacha20poly1305.key()
        let dateComponents = DateComponents(timeZone: TimeZone(identifier: "Europe/Berlin"), year: 2022, month: Int.random(in: 1..<12), day: Int.random(in: 1..<28), hour: Int.random(in: 1..<11), minute: 0, second: 0)
        let date = Calendar(identifier: .gregorian).date(from: dateComponents)
        print("date", date!)
        return PrivateKey(name: name, keyBytes: hash, creationDate: date!)
    }

    public static func dummyKey() -> PrivateKey {
        let hash: Array<UInt8> = [36,97,114,103,111,110,50,105,100,36,118,61,49,57,36,109,61,54,53,53,51,54,44,116,61,50,44,112,61,49,36,76,122,73,48,78,103,67,57,90,69,89,76,81,80,70,76,85,49,69,80,119,65,36,83,66,66,49,65,85,86,74,55,82,85,90,116,79,67,111,104,82,100,89,67,71,57,114,90,119,109,81,47,118,74,77,121,48,85,71,108,69,103,66,122,79,77]
        let dateComponents = DateComponents(timeZone: TimeZone(identifier: "Europe/Berlin"), year: 2022, month: 2, day: 9, hour: 5, minute: 0, second: 0)
        let date = Calendar(identifier: .gregorian).date(from: dateComponents)

        return PrivateKey(name: "test", keyBytes: hash, creationDate: date ?? Date())
    }
}
