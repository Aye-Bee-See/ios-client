import Foundation

/// Invitations (API "Invitations"): how a group admin comes into being, either joining the inviting group
/// (`member`) or founding a new group the inviter vouches for (`group`). In end-to-end mode nobody can make an
/// account for someone else, so this is the only way in for a group admin. The token is 24 characters of
/// Crockford base32, typed as forgivingly as an invite code: the server folds it the same way.
public enum InvitationToken {
  public static let length = 24

  public static func isWellFormed(_ input: String) -> Bool {
    let n = InviteCode.normalise(input)
    return n.count == length && n.allSatisfy(InviteCode.alphabet.contains)
  }

  /// The first problem with what was typed, as a sentence, or nil when it looks right. The check is rate limited.
  public static func problem(_ input: String) -> String? {
    let n = InviteCode.normalise(input)
    if n.isEmpty { return "Enter the invitation you were given." }
    if let bad = n.first(where: { !InviteCode.alphabet.contains($0) }) { return "Invitations never contain the character \(bad). Check for a look-alike." }
    if n.count != length { return "That is \(n.count) characters; an invitation has \(length)." }
    return nil
  }

  /// Six groups of four, for display.
  public static func pretty(_ input: String) -> String { InviteCode.pretty(input) }
}

/// What was typed into the one box for codes, told apart by length: a person with either kind of paper lands
/// in the right flow. A claim token is also 24 characters, but it comes with its own screen and its own link.
public enum EntryCode: Equatable, Sendable {
  case inviteCode(String)
  case invitation(String)

  /// Nil when the length is neither; the caller then words the problem.
  public static func classify(_ input: String) -> EntryCode? {
    let n = InviteCode.normalise(input)
    switch n.count {
    case InviteCode.length: return .inviteCode(n)
    case InvitationToken.length: return .invitation(n)
    default: return nil
    }
  }

  /// The first problem with what was typed, whichever kind it looks like.
  public static func problem(_ input: String) -> String? {
    let n = InviteCode.normalise(input)
    if n.isEmpty { return "Enter the code on your slip, or the invitation you were given." }
    if let bad = n.first(where: { !InviteCode.alphabet.contains($0) }) { return "Codes never contain the character \(bad). Check for a look-alike." }
    if classify(n) == nil { return "That is \(n.count) characters. An invite code has \(InviteCode.length); an invitation has \(InvitationToken.length)." }
    return nil
  }
}

/// `GET /invitation/invitation?token=`: what the token invites its holder to, before anything is asked.
public struct InvitationInfo: Equatable, Sendable {
  public enum Kind: String, Sendable { case member, group }
  public let kind: Kind
  public let inviteeName: String?
  /// The group being joined (`member`) or vouching (`group`); nil when an admin invited with nobody vouching.
  public let groupName: String?
  public let expiresAt: Date?
  /// `activation: "admin_review"`: a new group waits for an admin before it can act.
  public let waitsForReview: Bool
  /// What the acceptance form may say about a new group. Empty for `member`.
  public let groupFields: Set<String>
}

/// The new group's profile, for a `group` invitation. Only the fields the invitation allows are sent.
public struct NewGroupProfile: Equatable, Sendable {
  public var name = ""
  public var city = ""
  public var country = ""
  public var about = ""
  public var website = ""
  public var email = ""
  public init() {}
}

/// What accepting made.
public struct AcceptedInvitation: Equatable, Sendable {
  public let groupName: String
  public let waitsForReview: Bool
}
