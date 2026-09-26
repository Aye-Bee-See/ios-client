import Foundation

/// Pen names (API "Pen names"): the name a writer's letters are signed with and a prisoner writes back to. Unique
/// across the site whatever the case or spacing; every name an account has used stays its own for ever. The shape
/// is checked here before the rate-limited public check: 3 to 40 characters, starting with a letter, of letters in
/// any script, digits, spaces, hyphens, apostrophes and dots. The server stores one space between words.
public enum PenName {
  public static let minLength = 3
  public static let maxLength = 40
  public static let rules = "3 to 40 characters, starting with a letter: letters, digits, spaces, hyphens, apostrophes and dots."

  /// One space between words, as the server stores it.
  public static func normalise(_ input: String) -> String {
    input.split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }

  /// How the server tells names apart: case and spacing do not count.
  static func key(_ input: String) -> String { normalise(input).lowercased() }

  private static func allowed(_ c: Character) -> Bool {
    c.isLetter || c.isNumber || c == " " || c == "-" || c == "'" || c == "\u{2019}" || c == "."
  }

  /// The first problem with the shape, as a sentence, or nil when it looks right.
  public static func problem(_ input: String) -> String? {
    let n = normalise(input)
    if n.count < minLength { return "A pen name has at least \(minLength) characters." }
    if n.count > maxLength { return "A pen name has at most \(maxLength) characters." }
    if n.first?.isLetter != true { return "A pen name starts with a letter." }
    if let bad = n.first(where: { !allowed($0) }) { return "\(bad) cannot be in a pen name." }
    return nil
  }
}

/// The server's answer to "is this name free?"
public struct PenNameCheck: Equatable, Sendable {
  public let name: String
  public let available: Bool
  public let reason: String?
  public let twoParts: Bool
}

/// `GET /auth/pen-name`: the account's names, current first, and what the limits (API #127) leave it today.
public struct PenNames: Equatable, Sendable {
  public struct Row: Equatable, Sendable, Identifiable {
    public let name: String
    public let current: Bool
    public let since: Date?
    public var id: String { name }
  }

  public let current: String?
  public let names: [Row]
  /// When the next change of any kind may happen. Nil for an account that has never had a name: it may choose at once.
  public let changeAllowedAt: Date?
  /// Brand-new names left in the rolling year. Going back to one of the account's own old names does not spend one.
  public let newNamesLeft: Int
  /// When the oldest counted new name leaves the year, so another becomes possible. Nil when none is counted.
  public let newNamesWindowEnds: Date?
  public let cooldownDays: Int
  public let newPerYear: Int

  public func canChange(at now: Date = Date()) -> Bool { changeAllowedAt.map { $0 <= now } ?? true }

  /// An old name of this account's, which it may take back even with no new names left.
  public func isOwnOldName(_ input: String) -> Bool {
    let k = PenName.key(input)
    return names.contains { !$0.current && PenName.key($0.name) == k }
  }

  /// The current name again, whatever the case or spacing: nothing to change.
  public func isCurrent(_ input: String) -> Bool { current.map { PenName.key($0) == PenName.key(input) } ?? false }
}
