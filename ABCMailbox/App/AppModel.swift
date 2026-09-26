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
  /// What the directory says about how much mail the group handles, and the one number of it that a person types.
  case groupNumbers
  /// Invite codes (API PR #116): print slips, see the quota, cancel unused codes.
  case inviteCodes
  case changePassword
  /// A writer's pen name, and the limits on changing it (API #127).
  case penName
  case deleteAccount
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
  /// Reopen a letter that is waiting in the outbox; sending it again replaces the queued copy.
  var outboxId: String?
  /// Send a letter that came back again (API PR #105): starts from its text, and the new letter names it.
  var resendOf: Int?
  /// A queued letter held as `reseal_needed` (API PR #106): starts from its text, and once the new letter
  /// is sent, sealed to whoever mails to the new facility, the held one is deleted.
  var replaceHeldId: Int?
}

/// Sign-in is a full-screen flow of its own, on top of whichever tab asked for it.
enum AuthRoute: Hashable {
  /// `token` is set when the screen was opened by a claim link.
  case claim(token: String?)
  /// `code` is set when the screen was opened by a join link (API PR #116).
  case join(code: String?)
  /// An invitation to be a group admin: to join a group, or to found one. Reached from the invite code box.
  case invitation(token: String?)
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

  /// Group members with keys of their own who are waiting to be handed the group's (API PR #95, step 3).
  private(set) var membersWaiting: [GroupMember] = []

  private(set) var toast: Toast?
  @ObservationIgnored private var toastTask: Task<Void, Never>?

  init(container: AppContainer) {
    self.container = container
    container.activity.notifier = announcer
    announcer.onOpen = { [weak self] chat in self?.openFromNotification(chat: chat) }
  }

  let notifier = OutboxNotifier()
  let announcer = ActivityAnnouncer()

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

  /// A join link (the QR on an invite slip) opens the join form with the code filled in.
  func openJoin(code: String?) {
    authPresented = true
    authPath = [.join(code: code)]
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

  // MARK: What is new (the notification feed, API PR #96)

  /// Letters waiting to go plus news not yet seen: the number on the Inbox tab.
  var inboxBadge: Int { container.outbox.items.count + container.activity.unread }

  /// The app is open: fetch the news and say it here, as a toast. Looking at the Inbox counts as reading it.
  func syncActivity() async {
    let fresh = await container.activity.sync()
    if let summary = ActivitySummary(fresh) { show(fresh.count == 1 ? summary.body : "\(summary.title). \(summary.body)") }
    if tab == .inbox, inboxPath.isEmpty { await container.activity.markAllRead() }
  }

  /// A tapped notification: the conversation when all its news was about one, otherwise the Inbox.
  func openFromNotification(chat: Int?) {
    guard user != nil else { return }
    authPresented = false
    tab = .inbox
    inboxPath = chat.map { [.thread(chatId: $0)] } ?? []
    Task { await container.activity.markAllRead() }
  }

  // MARK: Key set-up (API PR #95)

  /// A group member's share of the move to end-to-end encryption, after every sign-in and launch,
  /// without asking. The one thing left to a person is handing the group key to a member who lacks it.
  func setUpKeys() async {
    guard user?.role == Role.chapter else { membersWaiting = []; return }
    let done = await container.group.setUpKeys()
    membersWaiting = done.membersWaiting
    var said: [String] = []
    if done.madeGroupKey { said.append("Your group's encryption key was made on this phone.") }
    if done.writersGivenKeys > 0 { said.append(done.writersGivenKeys == 1 ? "A writer in your care was given keys." : "\(done.writersGivenKeys) writers in your care were given keys.") }
    if done.lettersShared > 0 { said.append(done.lettersShared == 1 ? "A reply was shared with its writer." : "\(done.lettersShared) replies were shared with their writers.") }
    if !said.isEmpty { show(said.joined(separator: " ")) }
  }

  /// After the key page hands the key, stops, or passes the role on: what the Inbox says is waiting follows.
  func refreshMembersWaiting() async {
    guard user?.role == Role.chapter, let roster = try? await container.group.roster(), roster.iAmOwner else { membersWaiting = []; return }
    membersWaiting = roster.members.filter { $0.hasOwnKey && !$0.holdsGroupKey && !$0.isMe }
  }

  /// One confirmation, as the API's guide allows, rather than silently: it grants someone the means to
  /// read the group's mail, and doing it unasked would quietly undo "Stop" on the Group key screen.
  func handKeyToWaitingMembers() async {
    var failed: String?
    for member in membersWaiting {
      do { try await container.group.handKey(to: member.id) } catch { failed = AppError.from(error).userMessage ?? "The key could not be handed over." }
    }
    await setUpKeys()
    show(failed ?? "Done. They can read the group's letters from their next sign-in or refresh.")
  }

  // MARK: The outbox

  /// Sends what is waiting and says what happened: at launch, on coming to the front, after sign-in.
  func flushOutbox() async {
    container.outbox.reload()
    guard container.outbox.hasWaiting else { return }
    report(await container.outbox.flush())
  }

  /// In the app, a toast. The words are the ones the lock-screen notification uses: they name nobody.
  func report(_ outcome: FlushOutcome) {
    if let text = OutboxNotifier.text(outcome) { show(text) }
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
