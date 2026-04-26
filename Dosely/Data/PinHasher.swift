import Foundation
import CommonCrypto

/// PBKDF2-SHA256 with 100k iterations and a 16-byte random salt, exposed as
/// pure functions for storage in Core Data. We use CommonCrypto rather than
/// CryptoKit because PBKDF2 didn't land in CryptoKit's public API until iOS 17,
/// and the project targets iOS 16. See CLAUDE.md ▸ "Account model" for context.
///
/// Rationale: a 4–6 digit PIN has 10⁴–10⁶ possible values, well within reach
/// of an unsalted SHA-256 sweep. PBKDF2 with 100k iterations slows each guess
/// to ~50ms on an A14, which makes brute force practical only for a determined
/// attacker with the device unlocked. Combined with the existing 3-strikes
/// supervisor notification (PersonRepository.verifyPin), that's adequate
/// defence-in-depth for the threat model: a curious household member.
enum PinHasher {
    static let iterations: UInt32 = 100_000
    static let keyLength = 32
    static let saltLength = 16

    /// Derives a hash from a plaintext PIN and a per-person salt. Returns
    /// `nil` only on a CommonCrypto failure (extremely rare).
    static func hash(pin: String, salt: Data) -> Data? {
        var derived = Data(count: keyLength)
        let saltBytes = [UInt8](salt)
        let pinBytes = Array(pin.utf8)

        let status = derived.withUnsafeMutableBytes { keyPtr -> Int32 in
            saltBytes.withUnsafeBufferPointer { saltPtr -> Int32 in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    pinBytes,
                    pinBytes.count,
                    saltPtr.baseAddress,
                    saltBytes.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    iterations,
                    keyPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    keyLength
                )
            }
        }
        return status == kCCSuccess ? derived : nil
    }

    /// Generates a cryptographically-random 16-byte salt.
    static func generateSalt() -> Data {
        var salt = Data(count: saltLength)
        _ = salt.withUnsafeMutableBytes { ptr in
            SecRandomCopyBytes(kSecRandomDefault, saltLength, ptr.baseAddress!)
        }
        return salt
    }

    /// Constant-time hash comparison.
    static func verify(pin: String, hash storedHash: Data, salt: Data) -> Bool {
        guard let computed = self.hash(pin: pin, salt: salt) else { return false }
        guard computed.count == storedHash.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<computed.count {
            diff |= computed[i] ^ storedHash[i]
        }
        return diff == 0
    }
}
