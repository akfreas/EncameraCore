import Foundation
import Sodium // Sodium is available within EncameraCore

internal enum TestDataGenerator {

    /// Generates random bytes suitable for a private key, using the length specified by Sodium.
    /// This is intended for use in unit tests where actual cryptographic strength isn't the primary goal,
    /// but matching the expected data format is.
    static func generateRandomKeyBytes() -> [UInt8] {
        let keyLength = Sodium().secretStream.xchacha20poly1305.KeyBytes
        return (0..<keyLength).map { _ in UInt8.random(in: 0...255) }
    }
} 