import Foundation

/// An account a group created for someone who has not claimed it yet.
public struct ManagedWriter: Equatable, Identifiable, Hashable, Sendable {
  public let id: Int
  public let name: String
  /// Nil when the address is the API's `…@managed.example` placeholder.
  public let email: String?
  public let note: String?
  /// When a live claim token expires, or nil when there is none.
  public let tokenExpiresAt: Date?

  public var hasLiveToken: Bool { tokenExpiresAt.map { $0 > Date() } ?? false }
}

/// A group's numbers as its members see them (API PR #112). Only `before` is typed by anyone; the server counts
/// the rest. `published` is what the public page says: nil until the total reaches twenty.
public struct GroupNumbers: Equatable, Sendable {
  public let groupName: String
  public let before: Int
  public let countedHere: Int
  public let published: String?
  public let averageDaysToMail: Int?
  public var total: Int { before + countedHere }
  /// What the server publishes from, as the API documents it.
  public static let shownFrom = 20
}

/// Someone in the group, and whether they can open letters sealed to it.
public struct GroupMember: Equatable, Identifiable, Sendable {
  public let id: Int
  public let name: String
  /// False until their first sign-in on an end-to-end server, when their own keypair is made. Nothing can be sealed to them before that.
  public let hasOwnKey: Bool
  public let holdsGroupKey: Bool
  public let isMe: Bool
}

public struct IssuedToken: Equatable, Sendable {
  public let token: String
  public let expiresAt: Date?
}

/// A letter in the group's queue, with who it goes to: what a volunteer needs to address the envelope.
public struct QueueItem: Equatable, Identifiable, Sendable {
  public var letter: Letter
  public let prisoner: Prisoner?
  public var id: Int { letter.id }
}

/// Who is on the writer's side of a thread, as far as a group needs to know.
public struct ThreadWriter: Equatable, Sendable {
  public let id: Int
  public let name: String
  public let managedByGroupId: Int?
  public let anonymousForGroupId: Int?

  /// A group may write in a thread only for writers it manages, or as its own anonymous writer.
  public func canBeWrittenFor(by groupId: Int?) -> Bool {
    guard let groupId else { return false }
    return managedByGroupId == groupId || anonymousForGroupId == groupId
  }

  public var label: String { anonymousForGroupId != nil ? "Anonymous writer" : name }
}

/// Who may edit or withdraw a queued letter in a thread: the writer themselves, or a group member only
/// when the group writes for that writer. A group that merely relays (or was shared) a letter reads it
/// and prints it; the words are not theirs to change.
public func mayChangeLetters(viewerIsStaff: Bool, viewerGroupId: Int?, writer: ThreadWriter?) -> Bool {
  !viewerIsStaff || writer?.canBeWrittenFor(by: viewerGroupId) == true
}
