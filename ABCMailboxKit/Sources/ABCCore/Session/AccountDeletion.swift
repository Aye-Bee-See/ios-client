import Foundation

/// What went with the account, as the server counted it.
public struct DeletedAccount: Equatable, Sendable {
  public let letters: Int
  public let replies: Int
  public let attachments: Int
  public let threads: Int
  /// Letters that were waiting on this phone, never sent, and deleted with the rest.
  public let unsentLetters: Int
}

/// What the person should know before deleting, gathered best effort. Nothing here blocks the delete:
/// the server decides. It is so the screen can say, in numbers, what is about to go, and can explain
/// a refusal before the person has typed their password rather than after.
public struct AccountDeletionPreview: Equatable, Sendable {
  /// Conversations the account has on the server; nil if it could not be asked.
  public var conversations: Int?
  public var unsentLetters = 0
  /// End-to-end mode: this member is the only one who holds their group's key. The server refuses the
  /// delete (409), because the group could never read its letters again.
  public var isLastKeyHolder = false
  /// Other group admins who could be handed the key first.
  public var membersWhoCouldHoldTheKey: [String] = []
  /// This account is the group-owner admin and the group has other group admins (API PR #115). The server
  /// refuses the delete (409): ownership has to be passed on first.
  public var isOwnerWithOtherAdmins = false
  public var endToEnd = false
}

/// Deleting one's own account (API PR #104): the person goes, with everything they wrote and received.
/// The server does the deleting; this makes sure the phone keeps nothing either.
@MainActor
public final class AccountDeletion {
  private let sessions: SessionRepository
  private let modes: EncryptionModeRepository
  private let letters: LettersRepository
  private let group: GroupRepository
  private let drafts: DraftsRepository
  private let outbox: OutboxRepository
  private let activity: ActivityRepository

  init(sessions: SessionRepository, modes: EncryptionModeRepository, letters: LettersRepository, group: GroupRepository, drafts: DraftsRepository, outbox: OutboxRepository, activity: ActivityRepository) {
    self.sessions = sessions
    self.modes = modes
    self.letters = letters
    self.group = group
    self.drafts = drafts
    self.outbox = outbox
    self.activity = activity
  }

  static let wrongPassword = AppError.forbidden("That is not this account's password. Nothing was deleted.")
  static let ownerRefusal = AppError.conflict("You are your group's group-owner admin and the group has other group admins. Make one of them the owner first (Group key, on the Inbox). Nothing was deleted.", name: "AccountDeleteError", condition: "group_owner")
  static let lastHolderRefusal = AppError.conflict("You are the last person holding your group's key. Hand it to another group admin first (Group key, on the Inbox), or your group could never read its letters again. Nothing was deleted.", name: "AccountDeleteError", condition: "last_key_holder")

  public func preview() async -> AccountDeletionPreview {
    var p = AccountDeletionPreview()
    guard let user = sessions.state.user else { return p }
    p.endToEnd = await modes.current() == .e2e
    outbox.reload()
    p.unsentLetters = outbox.items.count
    // A writer's conversations are all theirs. A group member's list is the group's, which stays, so no number is shown.
    if !user.isStaff { p.conversations = (try? await letters.threads(page: 1, pageSize: 1))?.total }
    if user.role == Role.chapter, let roster = try? await group.roster() {
      p.isOwnerWithOtherAdmins = roster.ownerId == user.id && !roster.others.isEmpty
      if p.endToEnd, roster.members.contains(where: { $0.isMe && $0.holdsGroupKey }) {
        p.isLastKeyHolder = !roster.members.contains { !$0.isMe && $0.holdsGroupKey }
        p.membersWhoCouldHoldTheKey = roster.members.filter { !$0.isMe && $0.hasOwnKey && !$0.holdsGroupKey }.map(\.name)
      }
    }
    return p
  }

  /// Throws what the server said and deletes nothing, here or there, unless the server deleted the account.
  @discardableResult
  public func deleteMyAccount(password: String) async throws -> DeletedAccount {
    guard let user = sessions.state.user else { throw AppError.unauthorized("You are signed out.") }
    outbox.reload()
    let unsent = outbox.items.count
    // The phone proves the password first, by signing in with it (in whichever scheme the account uses), and
    // sends nothing if that fails; `deleteAccount` says why. Both a wrong password and the server's own 403
    // read the same here: nothing happened.
    let gone: DeletedUserDTO
    do {
      gone = try await sessions.deleteAccount(password: password)
    } catch let e as AppError {
      // The API answers a wrong password with 403 and its own sentence; say plainly that nothing happened.
      if case .forbidden = e { throw Self.wrongPassword }
      // A refusal with a code (API PR #117) is worded here; one without keeps the server's sentence.
      switch e.conflictCondition {
      case "group_owner": throw Self.ownerRefusal
      case "last_key_holder": throw Self.lastHolderRefusal
      default: throw e
      }
    }
    // The session and the keys went with `deleteAccount`. What else this phone held for the account:
    drafts.deleteAll(userId: user.id)
    outbox.deleteAll(userId: user.id)
    activity.forget(userId: user.id)
    return DeletedAccount(letters: gone.letters ?? 0, replies: gone.replies ?? 0, attachments: gone.attachments ?? 0, threads: gone.threads ?? 0, unsentLetters: unsent)
  }
}
