import ABCCore
import BackgroundTasks
import SwiftUI
import UserNotifications

/// Letters written without a connection, above the inbox until they are gone. A waiting letter
/// needs nothing from the writer; a refused one does, and says what, in the server's words.
struct OutboxSection: View {
  let app: AppModel
  @State private var trying = false
  @State private var confirmDelete: OutboxItem?

  var body: some View {
    let items = app.container.outbox.items
    if !items.isEmpty {
      VStack(alignment: .leading, spacing: 10) {
        Text("Waiting to be sent").font(Theme.titleLarge)
        // Android can promise "even if the app is closed". iOS decides for itself when a closed app may run.
        Text("Written without a connection. They are sent when this phone is next online: at once if the app is open, otherwise when iOS next lets it work in the background, or when you open it.").font(Theme.caption)
        ForEach(items) { item in row(item) }
        if items.contains(where: { $0.problem == nil }) {
          Button(trying ? "Trying…" : "Try to send now") { Task { await tryNow() } }.buttonStyle(.link).disabled(trying)
        }
      }
      .padding(16).frame(maxWidth: .infinity, alignment: .leading)
      .background(Theme.redWash, in: RoundedRectangle(cornerRadius: 8))
      .padding(.horizontal, 20).padding(.vertical, 8)
      .confirmationDialog("Delete this unsent letter?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }), titleVisibility: .visible) {
        Button("Delete", role: .destructive) { if let item = confirmDelete { app.container.outbox.delete(item.id) } }
        Button("Keep it", role: .cancel) {}
      } message: {
        Text("It has not been sent and is only on this phone. Deleting it cannot be undone.")
      }
    }
  }

  private func row(_ item: OutboxItem) -> some View {
    let p = item.payload
    let files = p.attachments.isEmpty ? "" : " · \(Format.plural(p.attachments.count, "file"))"
    return VStack(alignment: .leading, spacing: 2) {
      Text((p.fromPrisoner ? "Reply from \(p.prisonerName)" : "To \(p.prisonerName)") + (p.writingAs.map { " · as \($0)" } ?? "")).font(Theme.titleMedium)
      Muted("Written \(item.queuedAt.formatted(date: .abbreviated, time: .shortened))\(files)", font: Theme.caption)
      if let problem = item.problem { Text(item.letterWasSent ? problem : "Not sent. \(problem)").font(Theme.caption).foregroundStyle(Theme.red) }
      HStack(spacing: 20) {
        if item.letterWasSent {
          // The server has this letter; opening it again would post a second copy. All that is left is to take note.
          Button("Dismiss") { app.container.outbox.delete(item.id) }.buttonStyle(.quietLink)
        } else {
          Button("Edit") {
            app.push(.compose(ComposeRequest(
              prisonerId: p.prisonerId, writerId: p.fromPrisoner ? nil : p.asWriterId, writerName: p.writingAs,
              replyForUserId: p.fromPrisoner ? p.asWriterId : nil, outboxId: item.id
            )))
          }
          .buttonStyle(.quietLink)
          if item.problem != nil { Button("Try as it is") { app.container.outbox.retry(item.id); Task { await tryNow() } }.buttonStyle(.quietLink) }
          Button("Delete") { confirmDelete = item }.buttonStyle(.destructiveLink)
        }
      }
    }
  }

  /// For someone watching the screen: try now rather than wait for the system to notice the network.
  private func tryNow() async {
    guard !trying else { return }
    trying = true
    defer { trying = false }
    let outcome = await app.container.outbox.flush()
    if outcome.sent == 0, outcome.refused == 0, outcome.stillWaiting > 0 { app.show("Still no connection to the server. The letters are safe here.") } else { app.report(outcome) }
  }
}

/// Tells the writer what became of letters sent while they were not looking. The words are
/// deliberately bare: a notification shows on a lock screen, and who someone writes to in prison
/// is nobody else's business. Names and reasons are inside the app.
struct OutboxNotifier {
  static let backgroundTask = "me.paxana.abcmailbox.outbox"

  static func text(_ outcome: FlushOutcome) -> String? {
    var parts: [String] = []
    if outcome.sent == 1 { parts.append("A letter you wrote offline has been sent.") } else if outcome.sent > 1 { parts.append("\(outcome.sent) letters you wrote offline have been sent.") }
    if outcome.refused == 1 { parts.append("A letter could not be sent. Open the app to see why.") } else if outcome.refused > 1 { parts.append("\(outcome.refused) letters could not be sent. Open the app to see why.") }
    return parts.isEmpty ? nil : parts.joined(separator: " ")
  }

  /// Asked the first time a letter is queued, when the reason is plain: "tell me when it has gone".
  func askPermissionOnce() async {
    let center = UNUserNotificationCenter.current()
    if await center.notificationSettings().authorizationStatus == .notDetermined {
      _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }
  }

  /// Does nothing without permission; the outcome is on the Inbox either way.
  func notify(_ outcome: FlushOutcome) async {
    guard let text = Self.text(outcome) else { return }
    let content = UNMutableNotificationContent()
    content.title = "letters.support"
    content.body = text
    content.sound = .default
    try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: outcome.refused > 0 ? "outbox-refused" : "outbox-sent", content: content, trigger: nil))
  }

  /// Asks iOS to wake the app when there is a network. This is a request, not a schedule: iOS
  /// chooses the moment (often while charging, often hours later), and never runs an app the person
  /// has swiped away. It is the nearest thing iOS has to Android's WorkManager, and weaker.
  static func scheduleBackgroundSend() {
    let request = BGProcessingTaskRequest(identifier: backgroundTask)
    request.requiresNetworkConnectivity = true
    try? BGTaskScheduler.shared.submit(request)
  }
}
