import ABCCrypto
import Foundation

/// Claim tokens: 24 characters from `0-9 A-Z` without `I L O U`, case-insensitive
/// on entry. People read them off a screen or a slip of paper, so entry is
/// forgiving (spaces, dashes, lower case) and display is grouped in fours.
///
/// Checking the format locally matters: the API allows only 20 claim checks per
/// hour per address, so a typo should not cost a request.
public enum ClaimToken {
  public static let length = SecretCodes.length

  /// Upper-cases and drops everything that is not a letter or digit.
  public static func normalise(_ input: String) -> String { SecretCodes.normalise(input) }

  public static func isWellFormed(_ input: String) -> Bool { SecretCodes.isWellFormed(input) }

  /// The first problem with what was typed, as a sentence, or nil when it looks right.
  public static func problem(_ input: String) -> String? {
    let t = normalise(input)
    if t.isEmpty { return "Enter the token your group gave you." }
    if let bad = t.first(where: { !SecretCodes.alphabet.contains($0) }) {
      return "Tokens never contain the character \(bad). Check for a look-alike (I, L, O, and U are not used)."
    }
    if t.count < length { return "That is \(t.count) characters; a token has \(length)." }
    if t.count > length { return "That is \(t.count) characters; a token has only \(length)." }
    return nil
  }

  /// `ABCD-EFGH-…` for display.
  public static func pretty(_ input: String) -> String { SecretCodes.pretty(input) }

  /// An `abcmailbox://claim?token=…` link, or nil when the URL is something else. The token may be absent.
  public static func link(_ url: URL) -> Link? {
    guard url.scheme?.lowercased() == "abcmailbox", url.host?.lowercased() == "claim" else { return nil }
    return Link(token: URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "token" }?.value)
  }

  public struct Link: Equatable, Sendable {
    public let token: String?
  }
}

public struct ClaimInfo: Equatable, Sendable {
  public let writerName: String
  public let groupName: String?
  public let expiresAt: Date?
  public let endToEnd: Bool
}
