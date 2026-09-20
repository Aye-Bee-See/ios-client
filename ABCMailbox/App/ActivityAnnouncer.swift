import ABCCore
import BackgroundTasks
import SwiftUI
import UserNotifications

/// The account's news outside the app: a notification worded on the phone, naming nobody, and the
/// number on the app's icon. Inside the app the same news is a toast and a badge on the Inbox tab.
///
/// Without push (no Firebase project exists yet) the news is fetched when the app opens and
/// whenever iOS grants a background refresh, which it does at its own discretion: a few times a day
/// for an app that is used, rarely for one that is not. Push will make it prompt; it changes nothing here.
@MainActor
final class ActivityAnnouncer: NSObject, ActivityNotifier, UNUserNotificationCenterDelegate {
  static let backgroundTask = "me.paxana.abcmailbox.feed"
  private nonisolated static let identifier = "activity"
  /// Set by the app: open this conversation, or the Inbox when nil.
  var onOpen: ((Int?) -> Void)?

  private let center = UNUserNotificationCenter.current()

  override init() {
    super.init()
    center.delegate = self
  }

  // MARK: ActivityNotifier

  func show(_ summary: ActivitySummary, unread: Int) {
    let content = UNMutableNotificationContent()
    content.title = summary.title
    content.body = summary.body
    content.sound = .default
    content.badge = NSNumber(value: unread)
    if let chat = summary.chatId { content.userInfo = ["chat": chat] }
    // One identifier: newer news replaces the older notification rather than piling up beside it.
    center.add(UNNotificationRequest(identifier: Self.identifier, content: content, trigger: nil))
  }

  func clear() {
    center.removeDeliveredNotifications(withIdentifiers: [Self.identifier])
    center.setBadgeCount(0)
  }

  // MARK: Permission. Asked only when the person taps "Allow notifications" on the Account tab, or queues a letter offline.

  func status() async -> UNAuthorizationStatus { await center.notificationSettings().authorizationStatus }

  @discardableResult
  func askPermission() async -> Bool {
    (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
  }

  // MARK: Taps, and news that arrives while the app is open

  nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
    let request = response.notification.request
    guard request.identifier == Self.identifier else { return }
    let chat = request.content.userInfo["chat"] as? Int
    await MainActor.run { onOpen?(chat) }
  }

  nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
    // The outbox's report is worth a banner even with the app open; the feed's news is shown as a toast instead.
    notification.request.identifier == Self.identifier ? [] : [.banner, .sound]
  }

  // MARK: Background refresh

  /// A request, not a schedule: "not before six hours from now, and when you see fit".
  static func scheduleBackgroundRefresh() {
    let request = BGAppRefreshTaskRequest(identifier: backgroundTask)
    request.earliestBeginDate = Date().addingTimeInterval(6 * 3600)
    try? BGTaskScheduler.shared.submit(request)
  }
}
