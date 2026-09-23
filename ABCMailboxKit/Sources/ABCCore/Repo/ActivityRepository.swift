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
  func forget(userId: Int) { defaults.removeObject(forKey: lastSeenKey(userId)) }

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
      return Activity(id: e.id, kind: Activity.kind(event: e.event, status: status, held: held, action: action, member: member, owner: owner, me: user), chatId: e.chat, messageId: e.message, count: count)
    }
    if let newest = entries.map(\.id).max() { defaults.set(newest, forKey: lastSeenKey(user)) }
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
