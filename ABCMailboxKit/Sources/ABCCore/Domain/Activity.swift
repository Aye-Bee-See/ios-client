import Foundation

/// One entry of the account's notification feed. The server sends an event name and ids; what it *says*
/// is decided here, on the phone. The sentences name nobody and quote nothing, because they end up on
/// lock screens: the names are inside the app, behind the phone's lock.
public struct Activity: Equatable, Identifiable, Sendable {
  public enum Kind: Equatable, Sendable {
    case reply, printed, mailed, queuedForGroup, changeApproved, changeRejected
    /// An event this version has never heard of still deserves a word: the app will show whatever it is.
    case other
  }

  public let id: Int
  public let kind: Kind
  public let chatId: Int?
  public let messageId: Int?

  public var sentence: String {
    switch kind {
    case .reply: return "A reply to one of your letters has arrived."
    case .printed: return "One of your letters has been printed."
    case .mailed: return "One of your letters is in the post."
    case .queuedForGroup: return "A letter is waiting for your group to print it."
    case .changeApproved: return "A change you proposed to the directory was approved."
    case .changeRejected: return "A change you proposed to the directory was not accepted."
    case .other: return "There is something new in your account."
    }
  }

  static func kind(event: String, status: String?) -> Kind {
    switch (event, status) {
    case ("letter.reply", _): return .reply
    case ("letter.status", "printed"): return .printed
    case ("letter.status", "mailed"): return .mailed
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
