import Foundation
import Observation

/// Shows and clears the announcement outside the app. A protocol so this package needs no UIKit, and tests no phone.
@MainActor
public protocol ActivityNotifier: AnyObject {
  func show(_ summary: ActivitySummary, unread: Int)
  func clear()
}

/// What is new in the account: a reply arrived, a letter was printed or mailed, a letter is waiting for
/// the group. The feed (API PR #96) works without push: the app fetches it when it opens, when iOS lets
/// it refresh in the background, and, once push exists, when the doorbell rings. A push will carry
/// nothing at all, so this fetch is where the news actually comes from either way.
@MainActor @Observable
public final class ActivityRepository {
  /// Entries the account has not read, for the badge on the Inbox tab.
  public private(set) var unread = 0

  @ObservationIgnored private let api: APIClient
  @ObservationIgnored private let sessions: SessionRepository
  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored public weak var notifier: ActivityNotifier?
  /// Run when the feed says this account's group key or role changed (API PR #115), from every fetch, in the
  /// background included: the cursor moves on with each fetch, so the reload has to happen where the fetch does.
  @ObservationIgnored var onGroupKeyChange: (@MainActor () async -> Void)?

  init(api: APIClient, sessions: SessionRepository, defaults: UserDefaults) {
    self.api = api
    self.sessions = sessions
    self.defaults = defaults
    sessions.onSignedOut.append { [weak self] in
      self?.unread = 0
      self?.notifier?.clear()
    }
  }

  private var userId: Int? { sessions.state.user?.id }
  /// Per account: two people sharing a phone each have their own place in their own feed.
  private func lastSeenKey(_ user: Int) -> String { "activity_last_seen_\(user)" }

  /// The account is gone: so is its place in a feed that no longer exists.
  func forget(userId: Int) {
    defaults.removeObject(forKey: lastSeenKey(userId))
    defaults.removeObject(forKey: blockNoticesKey(userId))
  }

  // MARK: What a group said when it blocked this writer (API #171)

  private func blockNoticesKey(_ user: Int) -> String { "group_block_notices_\(user)" }

  private func blockNotices(_ user: Int) -> BlockNoticesBox { BlockNoticesBox(defaults: defaults, key: blockNoticesKey(user)) }

  /// The group's name and its reason, as the writer was told, while the block stands. Nil when this phone was not
  /// told (another device read the feed first): the letter is still said to be held, without the reason.
  public func blockNotice(groupId: Int) -> GroupBlockNotice? {
    guard let user = userId else { return nil }
    return blockNotices(user)[groupId]
  }

  /// Fetches what is new since this phone last looked. Quiet when signed out or offline: this is housekeeping.
  ///
  /// `announce` hands the news to the notifier (a notification), for when nobody is looking at the app.
  /// Either way the fresh entries are returned, so an open app can say it in its own way.
  @discardableResult
  public func sync(announce: Bool = false) async -> [Activity] {
    guard let user = userId else { unread = 0; return [] }
    let since = defaults.object(forKey: lastSeenKey(user)) as? Int
    guard let envelope: APIEnvelope<[NotificationDTO]> = try? await api.get("auth/notifications", query: [("since", since.map(String.init)), ("unread", "true")]) else { return [] }
    guard userId == user else { return [] } // signed out, or someone else signed in, while the request was in flight
    let entries = envelope.data ?? []
    unread = envelope.unread ?? entries.count
    let fresh = entries.filter { $0.readAt == nil }.map { e -> Activity in
      var status: String?
      if case .string(let s)? = e.detail?["status"] { status = s }
      var held = 0
      if case .number(let n)? = e.detail?["held"] { held = Int(n) }
      var count = 1
      if case .number(let n)? = e.detail?["count"], n >= 1 { count = Int(n) }
      var action: String?
      if case .string(let s)? = e.detail?["action"] { action = s }
      var member: Int?, owner: Int?
      if case .number(let n)? = e.detail?["member"] { member = Int(n) }
      if case .number(let n)? = e.detail?["owner"] { owner = Int(n) }
      var paper = false
      if case .bool(let b)? = e.detail?["paper"] { paper = b }
      var decision: String?
      if case .string(let s)? = e.detail?["decision"] { decision = s }
      return Activity(id: e.id, kind: Activity.kind(event: e.event, status: status, held: held, action: action, member: member, owner: owner, me: user, paper: paper, decision: decision), chatId: e.chat, messageId: e.message, count: count)
    }
    // Which group blocked this writer, and why (API #171). The feed is the only place the API says so, and a feed
    // sentence names nobody, so it is kept here for the app to say where only the writer sees it.
    for e in entries.sorted(by: { $0.id < $1.id }) where e.event == "writer.block" {
      guard case .object(let group)? = e.detail?["chapter"], case .number(let gid)? = group["id"] else { continue }
      var name: String?, reason: String?, action: String?
      if case .string(let s)? = group["name"] { name = s }
      if case .string(let s)? = e.detail?["reason"] { reason = s }
      if case .string(let s)? = e.detail?["action"] { action = s }
      if action == "lifted" { blockNotices(user).removeValue(forKey: Int(gid)) } else { blockNotices(user)[Int(gid)] = GroupBlockNotice(groupName: name, reason: reason) }
    }
    if let newest = entries.map(\.id).max() { defaults.set(newest, forKey: lastSeenKey(user)) }
    if fresh.contains(where: \.kind.concernsGroupKey) { await onGroupKeyChange?() }
    if announce, let summary = ActivitySummary(fresh) { notifier?.show(summary, unread: unread) }
    return fresh
  }

  /// The person is looking at their Inbox: everything counts as seen, here and on their other devices.
  public func markAllRead() async {
    guard userId != nil else { return }
    notifier?.clear()
    guard unread > 0 else { return }
    if let envelope: APIEnvelope<MarkedReadDTO> = try? await api.send("PUT", "auth/notifications/read", body: MarkReadRequest()) {
      unread = envelope.data?.unread ?? 0
    }
  }
}

/// What a group said when it blocked the writer: shown beside a held letter and a refused one, never on a lock screen.
public struct GroupBlockNotice: Codable, Equatable, Sendable {
  public let groupName: String?
  public let reason: String?
}

/// The writer's block notices in the app's defaults, keyed by group id. Small, and only what the writer was told.
struct BlockNoticesBox {
  let defaults: UserDefaults
  let key: String

  private var all: [Int: GroupBlockNotice] {
    get { defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([Int: GroupBlockNotice].self, from: $0) } ?? [:] }
    nonmutating set { if newValue.isEmpty { defaults.removeObject(forKey: key) } else { defaults.set(try? JSONEncoder().encode(newValue), forKey: key) } }
  }

  subscript(groupId: Int) -> GroupBlockNotice? {
    get { all[groupId] }
    nonmutating set { var current = all; current[groupId] = newValue; all = current }
  }

  func removeValue(forKey groupId: Int) { var current = all; current.removeValue(forKey: groupId); all = current }
}
