import ABCCore
import SwiftUI

/// One window, three tabs. Sign-in is a full-screen cover on top of whichever
/// tab asked for it; the one-time recovery code takes over everything.
struct RootView: View {
  @Environment(AppModel.self) private var app

  var body: some View {
    @Bindable var app = app
    ZStack {
      TabView(selection: $app.tab) {
        tab(.directory, "Directory", "book", path: $app.directoryPath) { DirectoryHomeView(app: app) }
        tab(.inbox, "Inbox", "envelope", path: $app.inboxPath) { InboxView() }
        tab(.account, "Account", "person", path: $app.accountPath) { AccountView(app: app) }
      }
      toastOverlay
      // A recovery code was just created (first sign-in on an end-to-end server, or a claim):
      // it takes over the screen until the writer confirms they saved it.
      if let code = app.sessions.pendingRecoveryCode {
        RecoveryCodeView(code: code) { app.sessions.recoveryCodeSaved() }
          .transition(.opacity)
          .zIndex(2)
      }
    }
    .animation(.default, value: app.sessions.pendingRecoveryCode)
    .fullScreenCover(isPresented: $app.authPresented) { AuthFlowView() .environment(app).tint(Theme.red) }
    .task { await app.container.modes.refresh() } // Ask the server which letter contract it speaks, once per launch.
    // Keep the offline copy of the directory fresh: at most one quiet download a day, and only if the server answers.
    .task { await app.container.offline.downloadIfOlderThan(hours: 24) }
    .onOpenURL { url in if let link = ClaimToken.link(url) { app.openClaim(token: link.token) } }
    .onChange(of: app.sessions.expiredCount) { app.show("Your session ended. Please sign in again.") }
    .onChange(of: app.user?.id) { old, new in
      // Signing in from signed-out changes nothing that was private; every other change does.
      if old != nil, old != new { app.closeEverything() }
    }
  }

  private func tab<Content: View>(_ tab: AppTab, _ title: String, _ symbol: String, path: Binding<[Route]>, @ViewBuilder root: @escaping () -> Content) -> some View {
    NavigationStack(path: path) {
      root()
        .background(Theme.paper)
        .navigationDestination(for: Route.self) { RouteView(route: $0, app: app).background(Theme.paper) }
    }
    .tabItem { Label(title, systemImage: symbol) }
    .tag(tab)
  }

  private var toastOverlay: some View {
    VStack {
      Spacer()
      if let toast = app.toast {
        Text(toast.message)
          .font(Theme.bodyMedium)
          .foregroundStyle(Theme.paper)
          .padding(.horizontal, 16).padding(.vertical, 12)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(Theme.ink, in: RoundedRectangle(cornerRadius: 8))
          .padding(.horizontal, 16).padding(.bottom, 64)
          .transition(.move(edge: .bottom).combined(with: .opacity))
          .accessibilityAddTraits(.isStaticText)
          .id(toast.id)
      }
    }
    .animation(.easeOut(duration: 0.2), value: app.toast)
    .allowsHitTesting(false)
    .zIndex(1)
  }
}

/// Every pushed screen, in one place.
struct RouteView: View {
  let route: Route
  let app: AppModel

  var body: some View {
    if readsDirectory { screen.savedCopyBanner(app) } else { screen }
  }

  private var readsDirectory: Bool {
    switch route {
    case .prisoners, .prisoner, .facilities, .facility, .groups, .group, .compose, .pickPrisoner: return true
    default: return false
    }
  }

  @ViewBuilder private var screen: some View {
    switch route {
    case .prisoners: PrisonersView(app: app)
    case .prisoner(let id): PrisonerView(app: app, id: id)
    case .facilities: FacilitiesView(app: app)
    case .facility(let id): FacilityView(app: app, id: id)
    case .groups: GroupsView(app: app)
    case .group(let id): GroupView(app: app, id: id)
    case .thread(let chatId): ThreadView(app: app, chatId: chatId)
    case .compose(let request): ComposeView(app: app, request: request)
    case .pickPrisoner(let writerId, let writerName):
      PrisonersView(app: app, title: writerName.map { "Write as \($0) to…" } ?? "Write to…") { prisonerId in
        app.replaceTop(with: .compose(ComposeRequest(prisonerId: prisonerId, writerId: writerId, writerName: writerName)))
      }
    case .letterWork(let messageId): LetterWorkView(app: app, messageId: messageId)
    case .addWriter: AddWriterView(app: app)
    case .handoff(let writerId, let writerName): HandoffView(app: app, writerId: writerId, writerName: writerName)
    case .groupKey: GroupKeyView(app: app)
    case .changePassword: ChangePasswordView(app: app)
    }
  }
}
