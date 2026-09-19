import ABCCore
import Observation
import SwiftUI

enum AppTab: Hashable {
  case directory, inbox, account
}

/// Navigation destinations as values instead of strings: a typo is a compile
/// error and arguments are associated values. Each tab keeps a stack of these.
enum Route: Hashable {
  case prisoners
  case prisoner(Int)
  case facilities
  case facility(Int)
  case groups
  case group(Int)
  case thread(chatId: Int)
  case compose(ComposeRequest)
  /// Choose who to write to. Group accounts say who the letter is from; nil means the anonymous writer.
  case pickPrisoner(writerId: Int?, writerName: String?)
  // Group member screens
  case letterWork(messageId: Int)
  case addWriter
  case handoff(writerId: Int, writerName: String)
  /// End-to-end servers: who in the group holds its key.
  case groupKey
  case changePassword
}

struct ComposeRequest: Hashable {
  var prisonerId: Int
  /// Set means "edit this queued letter" instead of "write a new one".
  var editMessageId: Int?
  /// Group accounts: the managed writer this letter is from. Nil means anonymous for a group, or yourself for a writer.
  var writerId: Int?
  var writerName: String?
  /// Group accounts: record a prisoner's reply on this writer's thread instead of writing a letter.
  var replyForUserId: Int?
}

/// Sign-in is a full-screen flow of its own, on top of whichever tab asked for it.
enum AuthRoute: Hashable {
  /// `token` is set when the screen was opened by a claim link.
  case claim(token: String?)
  case recover
}

struct Toast: Equatable, Identifiable {
  let id = UUID()
  let message: String
}

/// The app's navigation state and its doorway to `ABCCore`. One TabView, three
/// stacks, one sign-in cover. Screens change these values; SwiftUI does the rest.
@MainActor @Observable
final class AppModel {
  let container: AppContainer

  var tab: AppTab = .directory
  var directoryPath: [Route] = []
  var inboxPath: [Route] = []
  var accountPath: [Route] = []

  var authPresented = false
  var authPath: [AuthRoute] = []

  private(set) var toast: Toast?
  @ObservationIgnored private var toastTask: Task<Void, Never>?

  init(container: AppContainer) { self.container = container }

  var sessions: SessionRepository { container.sessions }
  var user: SessionUser? { container.sessions.state.user }

  // MARK: Navigation

  private var currentPath: [Route] {
    get { switch tab { case .directory: directoryPath; case .inbox: inboxPath; case .account: accountPath } }
    set { switch tab { case .directory: directoryPath = newValue; case .inbox: inboxPath = newValue; case .account: accountPath = newValue } }
  }

  func push(_ route: Route) { currentPath.append(route) }
  func pop() { if !currentPath.isEmpty { currentPath.removeLast() } }

  /// The screen on top is done and another takes its place (pick a prisoner, then write to them).
  func replaceTop(with route: Route) {
    pop()
    push(route)
  }

  /// A letter was sent from the compose screen on top. Opened from that very thread: go back to it
  /// (it reloads when it reappears) rather than stacking a second copy. Otherwise the thread replaces the form.
  func letterSent(chatId: Int) {
    pop()
    if currentPath.last != .thread(chatId: chatId) { push(.thread(chatId: chatId)) }
  }

  /// Nothing the previous account had open may stay reachable for the next one. Tabs keep a
  /// stack each, so a thread opened by one account would otherwise still be sitting on the
  /// Inbox tab for the next person to sign in.
  func closeEverything() {
    directoryPath = []
    inboxPath = []
    accountPath = []
  }

  // MARK: Sign-in flow

  func signIn() {
    authPath = []
    authPresented = true
  }

  /// `abcmailbox://claim?token=…` opens the claim form with the token filled in.
  func openClaim(token: String?) {
    authPath = [.claim(token: token)]
    authPresented = true
  }

  /// The sign-in flow ended with someone signed in.
  func authFinished(toast message: String? = nil, goToInbox: Bool = false) {
    authPresented = false
    authPath = []
    if goToInbox { tab = .inbox }
    if let message { show(message) }
  }

  // MARK: Toasts (what Android shows in a snackbar)

  func show(_ message: String) {
    toastTask?.cancel()
    toast = Toast(message: message)
    toastTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(3.5))
      if !Task.isCancelled { self?.toast = nil }
    }
  }
}
