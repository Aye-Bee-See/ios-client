import CryptoKit
import Foundation

/// Claim tokens and recovery codes: secrets a person reads off a screen or a
/// slip of paper and types back. 24 characters from `0-9 A-Z` without
/// `I L O U` (about 120 bits).
///
/// Every client MUST normalise a typed code the same way before using it,
/// because the normalised text is what goes into the key derivation: upper
/// case, letters and digits only. "abcd-efgh" and "ABCDEFGH" are one code.
public enum SecretCodes {
  public static let length = 24
  public static let alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
  private static let symbols = Array(alphabet)

  public static func generate() -> String {
    // 32 symbols, so a byte masked to 5 bits maps uniformly onto the alphabet.
    String(Sodium.randomBytes(length).map { symbols[Int($0 & 31)] })
  }

  public static func normalise(_ input: String) -> String {
    String(String.UnicodeScalarView(input.uppercased().unicodeScalars.filter(isLetterOrDigit)))
  }

  public static func isWellFormed(_ input: String) -> Bool {
    let t = normalise(input)
    return t.count == length && t.allSatisfy { alphabet.contains($0) }
  }

  /// `ABCD-EFGH-…` for display.
  public static func pretty(_ input: String) -> String {
    let t = Array(normalise(input))
    return stride(from: 0, to: t.count, by: 4).map { String(t[$0..<min($0 + 4, t.count)]) }.joined(separator: "-")
  }

  /// What the server stores for a claim token: SHA-256 (hex) of the normalised text.
  public static func hashHex(_ code: String) -> String {
    SHA256.hash(data: Data(normalise(code).utf8)).map { String(format: "%02x", $0) }.joined()
  }

  /// The same test as Kotlin's `Char.isLetterOrDigit`, which the Android client uses.
  private static func isLetterOrDigit(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.properties.generalCategory {
    case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter, .decimalNumber: return true
    default: return false
    }
  }
}
