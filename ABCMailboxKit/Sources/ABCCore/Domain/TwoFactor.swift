import Foundation

/// A sign-in waiting for its code (API #173): whose it is, and until when the code can finish it.
public struct TwoFactorChallenge: Equatable, Sendable {
  public let username: String
  public let expiresAt: Date?
}

/// Two-factor sign-in on the signed-in account, as `GET /auth/two-factor` says.
public struct TwoFactorStatus: Equatable, Sendable {
  public let enabled: Bool
  public let enabledAt: Date?
  public let recoveryCodesLeft: Int
  /// Required for this account (API #175); then it cannot be switched off.
  public let required: Bool
  /// Why: `superadmins`, `all_groups`, `group`.
  public let requiredBecause: [String]

  public init(enabled: Bool, enabledAt: Date?, recoveryCodesLeft: Int, required: Bool, requiredBecause: [String]) {
    self.enabled = enabled; self.enabledAt = enabledAt; self.recoveryCodesLeft = recoveryCodesLeft
    self.required = required; self.requiredBecause = requiredBecause
  }
}

/// What to put in an authenticator app: the link a QR code carries, and the secret for typing in by hand.
public struct TwoFactorSetup: Equatable, Sendable {
  public let secret: String
  public let otpauthUri: String
}

public enum TwoFactorCode {
  /// A six-digit code as typed: spaces and dashes dropped.
  public static func normalise(_ typed: String) -> String { typed.filter { !$0.isWhitespace && $0 != "-" } }

  /// Six digits, the only thing worth sending; anything else is a typo the server would only count against the account.
  public static func isWellFormed(_ typed: String) -> Bool {
    let n = normalise(typed)
    return n.count == 6 && n.allSatisfy(\.isASCII) && n.allSatisfy(\.isNumber)
  }

  /// A recovery code (`XXXXX-XXXXX`) is ten letters and digits; the server reads any case, spaces or dashes, and
  /// look-alikes. Only the length is checked here.
  public static func isRecoveryCodeShaped(_ typed: String) -> Bool {
    typed.filter { $0.isLetter || $0.isNumber }.count == 10
  }

  /// Who requires it, for the sentence "… requires two-factor sign-in". The narrowest reason wins.
  public static func requiredBy(_ because: [String]) -> String {
    if because.contains("group") { return "Your group" }
    if because.contains("all_groups") { return "The site, for every group admin," }
    if because.contains("superadmins") { return "The site, for every superadmin," }
    return "The site"
  }
}
