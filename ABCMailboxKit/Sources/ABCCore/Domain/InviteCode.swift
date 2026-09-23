import Foundation

/// Invite codes (API PR #116): how writers join. A chapter prints a batch as slips; a newcomer types one in.
/// Twelve characters of Crockford base32, shown as `XXXX-XXXX-XXXX`. Entry is forgiving: case, dashes and
/// spaces do not matter, and `O`, `I` and `L` read as `0`, `1` and `1`, as the server reads them.
public enum InviteCode {
  public static let length = 12
  public static let alphabet = Set("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

  /// Upper case, letters and digits only, with the look-alikes folded.
  public static func normalise(_ input: String) -> String {
    String(input.uppercased().compactMap { c -> Character? in
      switch c {
      case "O": return "0"
      case "I", "L": return "1"
      default: return c.isLetter || c.isNumber ? c : nil
      }
    })
  }

  public static func isWellFormed(_ input: String) -> Bool {
    let n = normalise(input)
    return n.count == length && n.allSatisfy(alphabet.contains)
  }

  /// The first problem with what was typed, as a sentence, or nil when it looks right. Checked here because the
  /// server's check is rate limited: a typo should not cost a request.
  public static func problem(_ input: String) -> String? {
    let n = normalise(input)
    if n.isEmpty { return "Enter the code on your slip." }
    if let bad = n.first(where: { !alphabet.contains($0) }) { return "Codes never contain the character \(bad). Check for a look-alike." }
    if n.count < length { return "That is \(n.count) characters; a code has \(length)." }
    if n.count > length { return "That is \(n.count) characters; a code has only \(length)." }
    return nil
  }

  /// `XXXX-XXXX-XXXX` for display.
  public static func pretty(_ input: String) -> String {
    let n = normalise(input)
    return stride(from: 0, to: n.count, by: 4).map { i in String(n[n.index(n.startIndex, offsetBy: i)..<n.index(n.startIndex, offsetBy: min(i + 4, n.count))]) }.joined(separator: "-")
  }

  /// The link printed as a QR on a slip, `https://letters.support/join?code=…`, or the app's own
  /// `abcmailbox://join?code=…`. Nil when the URL is something else; the code may be absent.
  public static func link(_ url: URL) -> Link? {
    let scheme = url.scheme?.lowercased(), host = url.host?.lowercased()
    let isApp = scheme == "abcmailbox" && host == "join"
    let isWeb = (scheme == "https" || scheme == "http") && host == "letters.support" && url.path == "/join"
    guard isApp || isWeb else { return nil }
    return Link(code: URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "code" }?.value)
  }

  public struct Link: Equatable, Sendable {
    public let code: String?
  }

  /// The web address a slip's QR opens, for the code as typed on it.
  public static func webLink(_ code: String) -> String { "https://letters.support/join?code=\(pretty(code))" }
}

/// Who is inviting, before a username is asked for.
public struct JoinInfo: Equatable, Sendable {
  public let groupId: Int
  public let groupName: String
  public let expiresAt: Date?
}

/// A batch just issued (API PR #116). The codes are shown once: the server keeps only their hashes.
public struct IssuedInviteCodes: Equatable, Sendable {
  public let batch: String
  public let label: String?
  public let expiresAt: Date?
  public let codes: [String]
  public let outstanding: Int
  public let limit: Int
}

public struct InviteCodeBatch: Equatable, Identifiable, Sendable {
  public let id: String
  public let label: String?
  public let createdAt: Date?
  public let expiresAt: Date?
  public let total: Int
  public let used: Int
  public let cancelled: Int
  public let expired: Int
  public let unused: Int
}

/// The chapter's codes as counts, never the codes: the server keeps no link between a code and the account it made.
public struct InviteCodeQuota: Equatable, Sendable {
  public let outstanding: Int
  public let limit: Int
  public let batches: [InviteCodeBatch]
}
