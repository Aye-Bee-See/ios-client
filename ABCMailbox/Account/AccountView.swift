import ABCCore
import Observation
import SwiftUI
import UserNotifications

@MainActor @Observable
final class AccountModel {
  private(set) var signingOut = false
  var serverDialog = false
  private(set) var serverChecking = false
  private(set) var serverResult: String?

  @ObservationIgnored private let app: AppModel
  @ObservationIgnored private var buildTaps = 0
  init(app: AppModel) { self.app = app }

  /// Five taps on the build line open the server dialog (debug builds only; the view gates it).
  func buildLineTapped() {
    buildTaps += 1
    if buildTaps >= 5 { buildTaps = 0; serverResult = nil; serverDialog = true }
  }

  func saveServer(_ input: String) async {
    serverChecking = true; serverResult = nil
    defer { serverChecking = false }
    do {
      let url = try await app.container.devServer.set(input)
      do { serverResult = "Reachable: \(try await app.container.devServer.check())" } catch {
        serverResult = "Saved \(url), but /health failed: \(AppError.from(error).userMessage ?? "no connection"). Is the API running and on the same Wi-Fi?"
      }
      // The saved directory belongs to the server it came from; a different server needs its own copy.
      try? await app.container.offline.download()
    } catch let invalid as DevServerRepository.InvalidURL {
      serverResult = invalid.message
    } catch {
      serverResult = "Invalid URL"
    }
  }

  func resetServer() async {
    await app.container.devServer.reset()
    serverResult = "Back to the default."
    try? await app.container.offline.download()
  }

  func signOut(everywhere: Bool) async {
    signingOut = true
    defer { signingOut = false }
    do {
      try await app.sessions.logout(everywhere: everywhere)
      app.show(everywhere ? "Signed out on every device." : "Signed out.")
    } catch {
      app.show("Signed out on this device. The server could not be told: \(AppError.from(error).userMessage ?? "no connection").")
    }
  }
}

struct AccountView: View {
  @State private var model: AccountModel
  private let app: AppModel

  init(app: AppModel) {
    self.app = app
    _model = State(initialValue: AccountModel(app: app))
  }

  var body: some View {
    Screen(spacing: 16, horizontal: 24) {
      Text("Account").font(Theme.headline).padding(.top, 8)
      if let user = app.user { signedIn(user) } else {
        Text("You are not signed in. Browsing the directory works without an account; writing letters needs one.").font(Theme.bodyLarge)
        Button("Sign in") { app.signIn() }.buttonStyle(.primaryCompact)
      }
      if app.user != nil {
        Divider().overlay(Theme.rule)
        NotificationsSection(app: app)
      }
      Divider().overlay(Theme.rule)
      OfflineCopySection(app: app)
      if app.user != nil {
        // Last, below everything someone comes to this tab for, and quiet: it should be findable, not inviting.
        Divider().overlay(Theme.rule)
        Button("Delete my account…") { app.push(.deleteAccount) }.buttonStyle(.destructiveLink)
      }
      buildLine
    }
    .toolbar(.hidden, for: .navigationBar)
    .statusBarBacking()
    .sheet(isPresented: $model.serverDialog) { DevServerSheet(app: app, model: model) }
  }

  @ViewBuilder private func signedIn(_ user: SessionUser) -> some View {
    Text(user.displayName).font(Theme.titleLarge)
    Muted("@\(user.username)", font: Theme.bodyLarge)
    Text(role(user)).font(Theme.bodyMedium)
    Divider().overlay(Theme.rule)
    // For members of a group: the group's public numbers, and the one of them that a person types.
    if user.role == Role.chapter, user.chapterId != nil { Button("Your group's numbers") { app.push(.groupNumbers) }.buttonStyle(.link) }
    Button("Change password") { app.push(.changePassword) }.buttonStyle(.link)
    Button("Sign out") { Task { await model.signOut(everywhere: false) } }.buttonStyle(.outlineWide).disabled(model.signingOut)
    Button("Sign out on every device") { Task { await model.signOut(everywhere: true) } }.buttonStyle(.link).disabled(model.signingOut)
  }

  private func role(_ user: SessionUser) -> String {
    switch user.role {
    case Role.chapter: return "Group admin" + (user.chapterId.map { " (group \($0))" } ?? " (no group assigned yet)")
    case Role.admin: return "Superadmin"
    default: return "Writer"
    }
  }

  private var buildLine: some View {
    let mode: String = switch app.container.modes.mode { case .e2e: "end-to-end encrypted"; case .server: "server mode"; case .unknown: "server not reached" }
    let server = app.container.devServer.isOverridden ? " · \(app.container.devServer.baseURL)" : ""
    return Muted("Build \(BuildInfo.version) · \(mode)\(server)", font: Theme.label)
      .padding(.vertical, 8)
      .contentShape(Rectangle())
      // Debug builds: five taps open the hidden server dialog.
      .onTapGesture { if BuildInfo.isDebug { model.buildLineTapped() } }
  }
}

/// The hidden developer sheet: reached by tapping the build line on the Account
/// tab five times, debug builds only. Lets a phone on the same Wi-Fi point at
/// the API on a development machine.
struct DevServerSheet: View {
  let app: AppModel
  let model: AccountModel
  @State private var text = ""
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      Screen(horizontal: 24) {
        Text("Debug builds only. Enter your computer's address on this Wi-Fi, for example 192.168.1.20 (port 3000 is assumed). The simulator reaches the Mac it runs on as localhost. Saving signs you out.").font(Theme.bodyMedium)
        LabeledField(label: "Base URL", hint: "Default: \(app.container.devServer.defaultURL)") {
          TextField("", text: $text).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
        }
        if let result = model.serverResult {
          Text(result).font(Theme.bodyMedium).foregroundStyle(result.hasPrefix("Reachable") ? Theme.ink : Theme.red)
        }
        Button(model.serverChecking ? "Checking…" : "Save and check") { Task { await model.saveServer(text) } }.buttonStyle(.primary)
        Button("Use default") {
          Task {
            await model.resetServer()
            // Show the address now in force; the field is local state and would otherwise keep the old one.
            text = app.container.devServer.baseURL
          }
        }
        .buttonStyle(.outlineWide)
      }
      .disabled(model.serverChecking)
      .navigationTitle("API server")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Close") { dismiss() } } }
    }
    .onAppear { text = app.container.devServer.baseURL }
    .presentationDetents([.medium, .large])
  }
}

/// Whether this phone may show notifications, asked for here and never at launch: a prompt with no
/// context gets a reflexive "Don't Allow", and iOS does not let an app ask twice.
struct NotificationsSection: View {
  let app: AppModel
  @State private var status: UNAuthorizationStatus?
  @Environment(\.openURL) private var openURL
  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Notifications").font(Theme.titleMedium)
      Muted("When a reply arrives, or a letter of yours is printed or mailed, this phone can tell you. The words name nobody: \"A reply to one of your letters has arrived.\" The app checks for news when you open it and a few times a day; nothing is sent to it from outside yet.", font: Theme.caption)
      switch status {
      case .notDetermined?:
        Button("Allow notifications") { Task { await app.announcer.askPermission(); status = await app.announcer.status() } }.buttonStyle(.outline)
      case .denied?:
        Muted("Turned off for this app in the phone's Settings.", font: Theme.caption)
        Button("Open Settings") { if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) } }.buttonStyle(.link)
      case nil:
        EmptyView()
      default:
        Muted("Allowed.", font: Theme.caption)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .task(id: scenePhase) { status = await app.announcer.status() } // coming back from Settings
  }
}
