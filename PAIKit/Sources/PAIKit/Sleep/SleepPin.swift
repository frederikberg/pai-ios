import Foundation

/// The PIN that guards changing or leaving sleep mode. It keeps a person from doing it on a whim;
/// it is not a security boundary, so it is stored as a salted digest in the app's own defaults,
/// which a reinstall clears: that reinstall is the way back in for a forgotten PIN.
public struct SleepPin: Codable, Equatable, Sendable {
    public static let lengths = 4...6

    /// Hex of 16 random bytes.
    public let salt: String
    /// Hex of `SHA-256(salt ‖ pin)`.
    public let digest: String

    public init(pin: String, salt: String) {
        self.salt = salt
        digest = Self.digest(pin: pin, salt: salt)
    }

    /// Whether `text` is something that can be a PIN: four to six digits.
    public static func isWellFormed(_ text: String) -> Bool {
        lengths.contains(text.count) && text.allSatisfy { $0.isASCII && $0.isNumber }
    }

    public func matches(_ pin: String) -> Bool {
        Self.digest(pin: pin, salt: salt) == digest
    }

    /// A fresh random salt.
    public static func randomSalt() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<16).map { _ in
            let byte = UInt8.random(in: 0...255, using: &generator)
            return (byte < 16 ? "0" : "") + String(byte, radix: 16)
        }.joined()
    }

    private static func digest(pin: String, salt: String) -> String {
        Sha256.digest(Array((salt + pin).utf8)).map { ($0 < 16 ? "0" : "") + String($0, radix: 16) }.joined()
    }
}
