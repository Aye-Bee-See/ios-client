import Foundation

/// The password rules are the clients' now (API PR #114): a split server never sees the password, so it can apply
/// none. The one hard rule is the length the network decided on. The meter is advice, not a gate: it is a rough
/// guess at how long a password would stand up to guessing, and it says so.
public enum PasswordRules {
  public static let minLength = 10
  public static let lengthHint = "At least \(minLength) characters. A few unrelated words with spaces make a strong one that is easy to remember."

  public enum Strength: Int, Sendable {
    case weak = 1, fair, good, strong
    public var label: String {
      switch self { case .weak: return "Weak"; case .fair: return "Fair"; case .good: return "Good"; case .strong: return "Strong" }
    }
    public var bars: Int { rawValue }
  }

  public static func isLongEnough(_ password: String) -> Bool { password.count >= minLength }

  /// Bits of guessing work, estimated the way most meters do: the size of the alphabet the characters come from,
  /// raised to the length, with penalties for the shortcuts people take (repeats, runs, one kind of character).
  /// Four or more words with spaces is treated as a passphrase and scored by words, which is what such passwords
  /// are made of. None of this can know a password is on a leaked list; nothing offline can.
  public static func strength(_ password: String) -> Strength {
    guard isLongEnough(password) else { return .weak }
    let words = password.trimmingCharacters(in: .whitespaces).split(whereSeparator: \.isWhitespace).filter { $0.count >= 3 }
    let bits: Double
    if words.count >= 4 {
      // A word from a large everyday vocabulary is worth about 14 bits (an 8,000-word list is 13; people pick from more).
      bits = Double(words.count) * 14 + Double(max(0, password.count - words.reduce(0) { $0 + $1.count })) * 0.5
    } else {
      var alphabet = 0
      if password.contains(where: \.isLowercase) { alphabet += 26 }
      if password.contains(where: \.isUppercase) { alphabet += 26 }
      if password.contains(where: \.isNumber) { alphabet += 10 }
      if password.contains(where: { !$0.isLetter && !$0.isNumber }) { alphabet += 20 }
      if password.unicodeScalars.contains(where: { $0.value > 127 }) { alphabet += 40 }
      var effective = Double(password.count)
      // Repeated characters and runs ("aaaa", "1234", "abcd") add nothing worth counting.
      let scalars = password.unicodeScalars.map { Int($0.value) }
      for i in 1..<scalars.count where abs(scalars[i] - scalars[i - 1]) <= 1 { effective -= 0.7 }
      bits = effective * log2(Double(max(alphabet, 2)))
    }
    switch bits {
    case ..<40: return .weak
    case ..<55: return .fair
    case ..<70: return .good
    default: return .strong
    }
  }
}
