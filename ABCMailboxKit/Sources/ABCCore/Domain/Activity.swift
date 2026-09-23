import Foundation

/// One entry of the account's notification feed. The server sends an event name and ids; what it *says*
/// is decided here, on the phone. The sentences name nobody and quote nothing, because they end up on
/// lock screens: the names are inside the app, behind the phone's lock.
public struct Activity: Equatable, Identifiable, Sendable {
  public enum Kind: Equatable, Sendable {
    case reply, printed, mailed, queuedForGroup, changeApproved, changeRejected
    /// The post brought a letter back (API PR #105). Why is inside the app, not on the lock screen.
    case returned
    /// Someone this account writes to was moved, or freed (API PR #106). `held`: how many of this writer's
    /// queued letters to them are waiting for the writer now.
    case moved(held: Int)
    case freed(held: Int)
    /// Group roles (API PR #115): the key set up, handed or withdrawn (to or from this account, or another's), rotated;
    /// the owner changed (to this account, or another); a group admin waiting for the key.
    case groupKeySet
    case groupKeyHanded(toMe: Bool)
    case groupKeyRemoved(fromMe: Bool)
    case groupKeyRotated
    case groupOwner(me: Bool)
    case groupWaiting

    /// The loaded group key may have changed hands or owners: the phone reloads it, so a copy handed or withdrawn takes effect without a sign-out.
    public var concernsGroupKey: Bool {
      switch self { case .groupKeySet, .groupKeyHanded, .groupKeyRemoved, .groupKeyRotated, .groupOwner: return true; default: return false }
    }
    /// An event this version has never heard of still deserves a word: the app will show whatever it is.
    case other
  }

  public let id: Int
  public let kind: Kind
  public let chatId: Int?
  public let messageId: Int?
  /// How many letters this entry is about. A group that marks thirty letters on a letter night tells each
  /// writer once (API PR #111): `messageId` is then nil, and `chatId` is set only if the letters share a conversation.
  public var count: Int = 1

  public var sentence: String {
    if count > 1 {
      switch kind {
      case .printed: return "\(count) of your letters have been printed."
      case .mailed: return "\(count) of your letters are in the mail."
      case .returned: return "\(count) of your letters came back in the mail."
      default: break
      }
    }
    switch kind {
    case .reply: return "A reply to one of your letters has arrived."
    case .printed: return "One of your letters has been printed."
    case .mailed: return "One of your letters is in the mail."
    case .returned: return "One of your letters came back in the mail."
    case .moved(let held): return "Someone you write to was moved to another facility." + Self.waiting(held)
    case .freed(let held): return "Someone you write to has been released." + Self.waiting(held)
    case .groupKeySet: return "Your group now has an encryption key."
    case .groupKeyHanded(true): return "You have been handed the group key. Letters will open from your next refresh."
    case .groupKeyHanded(false): return "The group key was handed to another group admin."
    case .groupKeyRemoved(true): return "Your copy of the group key has been withdrawn."
    case .groupKeyRemoved(false): return "A group admin's copy of the group key was withdrawn."
    case .groupKeyRotated: return "Your group's key was replaced. Anyone left out of the new key can no longer open its letters."
    case .groupOwner(true): return "You are now your group's group-owner admin."
    case .groupOwner(false): return "Your group has a new group-owner admin."
    case .groupWaiting: return "A group admin is waiting to be handed the group key."
    case .queuedForGroup: return "A letter is waiting for your group to print it."
    case .changeApproved: return "A change you proposed to the directory was approved."
    case .changeRejected: return "A change you proposed to the directory was not accepted."
    case .other: return "There is something new in your account."
    }
  }

  private static func waiting(_ held: Int) -> String {
    switch held {
    case ...0: return ""
    case 1: return " A letter you wrote them is waiting for you."
    default: return " \(held) letters you wrote them are waiting for you."
    }
  }

  /// `me` is the signed-in account, so that a key handed to it, or the role given to it, reads as "you".
  static func kind(event: String, status: String?, held: Int = 0, action: String? = nil, member: Int? = nil, owner: Int? = nil, me: Int? = nil) -> Kind {
    switch (event, status) {
    case ("group.key", _):
      switch action {
      case "set": return .groupKeySet
      case "handed": return .groupKeyHanded(toMe: me != nil && member == me)
      case "removed": return .groupKeyRemoved(fromMe: me != nil && member == me)
      case "rotated": return .groupKeyRotated
      default: return .other
      }
    case ("group.owner", _): return .groupOwner(me: me != nil && owner == me)
    case ("group.waiting", _): return .groupWaiting
    case ("letter.reply", _): return .reply
    case ("letter.status", "printed"): return .printed
    case ("letter.status", "mailed"): return .mailed
    case ("letter.status", "returned"): return .returned
    case ("prisoner.moved", _): return .moved(held: held)
    // The API sends this when someone becomes free. Any other status it may one day report is just news.
    case ("prisoner.status", "free"): return .freed(held: held)
    case ("letter.queued", _): return .queuedForGroup
    case ("submission.decided", "approved"): return .changeApproved
    case ("submission.decided", "rejected"): return .changeRejected
    default: return .other
    }
  }
}

/// Several entries as one announcement: a toast in the app, a notification outside it.
public struct ActivitySummary: Equatable, Sendable {
  public let title: String
  public let body: String
  /// Set when all the news is about one conversation, so tapping the announcement can open it.
  public let chatId: Int?

  public init?(_ fresh: [Activity]) {
    guard let first = fresh.first else { return nil }
    // Each kind of news once, in the order it happened to arrive; at most three sentences.
    var sentences: [String] = []
    for entry in fresh where !sentences.contains(entry.sentence) { sentences.append(entry.sentence) }
    let shown = sentences.prefix(3)
    let more = sentences.count - shown.count
    title = fresh.count == 1 ? "ABC Mailbox" : "\(fresh.count) updates about your letters"
    body = shown.joined(separator: " ") + (more > 0 ? " And \(more) more." : "")
    let chats = Set(fresh.map(\.chatId))
    chatId = chats.count == 1 ? first.chatId : nil
  }
}
