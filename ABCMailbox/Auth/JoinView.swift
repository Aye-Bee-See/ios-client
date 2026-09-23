import ABCCore
import Observation
import SwiftUI

/// Joining with an invite code (API PR #116): the code on a slip, then a username and password, then the account is
/// the person's from the first request. The keypair is made on this phone; the password never reaches the server.
@MainActor @Observable
final class JoinModel {
  var code: String
  var username = ""
  var password = ""
  var confirm = ""
  var email = ""
  var name = ""
  var showPassword = false
  var understood = false
  private(set) var info: JoinInfo?
  private(set) var busy = false
  private(set) var error: String?
  /// True when the code was refused as used, cancelled, expired or its chapter inactive: show the "ask for another" state.
  private(set) var codeDead = false

  @ObservationIgnored private let app: AppModel
  @ObservationIgnored private let arrivedWith: String?

  init(app: AppModel, code: String?) {
    self.app = app
    self.arrivedWith = code
    self.code = code.map(InviteCode.pretty) ?? ""
  }

  var passwordsMatch: Bool { password == confirm }
  var canCheck: Bool { !busy && !code.trimmingCharacters(in: .whitespaces).isEmpty }
  var canJoin: Bool {
    !busy && info != nil && (3...16).contains(username.trimmingCharacters(in: .whitespaces).count) && PasswordRules.isLongEnough(password) && passwordsMatch && understood
  }

  func edited() { error = nil }

  /// Arrived by the slip's QR: check the code straight away.
  func checkIfArrivedByLink() async {
    if let arrivedWith, info == nil, !busy, InviteCode.isWellFormed(arrivedWith) { await check() }
  }

  func startOver() {
    code = ""
    username = ""; password = ""; confirm = ""; email = ""; name = ""; understood = false
    info = nil; error = nil; codeDead = false
  }

  func check() async {
    let typed = code
    if let problem = InviteCode.problem(typed) { error = problem; return }
    busy = true; error = nil; codeDead = false
    defer { busy = false }
    do {
      let found = try await app.sessions.joinInfo(code: InviteCode.normalise(typed))
      code = InviteCode.pretty(typed)
      info = found
    } catch {
      fail(.from(error))
    }
  }

  func join() async {
    guard canJoin else { return }
    busy = true; error = nil
    defer { busy = false }
    do {
      try await app.sessions.join(code: InviteCode.normalise(code), username: username, password: password, email: email, name: name)
      password = ""; confirm = ""
      app.authFinished(toast: "Welcome. You are signed in.", goToInbox: true)
    } catch {
      fail(.from(error))
    }
  }

  private func fail(_ e: AppError) {
    codeDead = e.isGone
    switch e {
    case .notFound: error = "That code is not one the network issued. Check it against your slip."
    case .gone(_, condition: "used"): error = "This code has already been used. If that was you, sign in with the username and password you chose. If not, ask the group for another slip."
    case .gone(_, condition: "cancelled"): error = "The group cancelled this code. Ask them for another slip."
    case .gone(_, condition: "expired"): error = "This code has expired. Ask the group for another slip; they will tell you how long it is good for."
    case .gone(_, condition: "inactive"): error = "The group that printed this slip is not active on the network right now. Ask them what to do."
    case .gone: error = "This code can no longer be used. Ask the group for another slip."
    case .network: error = "Can't reach the server. Check your connection and try again."
    default: error = e.userMessage ?? "Something went wrong. Please try again."
    }
  }
}

struct JoinView: View {
  @State private var model: JoinModel
  private let app: AppModel

  init(app: AppModel, code: String?) {
    self.app = app
    _model = State(initialValue: JoinModel(app: app, code: code))
  }

  var body: some View {
    Screen(spacing: 14, horizontal: 24) {
      if let info = model.info { credentials(info) } else { codeEntry }
    }
    .disabled(model.busy)
    .navigationTitle("Join with an invite code")
    .navigationBarTitleDisplayMode(.inline)
    .task { await model.checkIfArrivedByLink() }
  }

  @ViewBuilder private var codeEntry: some View {
    Text("A support group gave you a slip with a code. Enter it to make your account; the group vouches for you and never sees what you write.").font(Theme.bodyLarge)
    LabeledField(label: "Invite code", hint: "12 letters and digits, as printed. Dashes, spaces and lower case are fine.") {
      TextField("XXXX-XXXX-XXXX", text: $model.code)
        .font(Theme.mono)
        .textInputAutocapitalization(.characters).autocorrectionDisabled().keyboardType(.asciiCapable)
        .submitLabel(.done).onSubmit { Task { await model.check() } }
        .accessibilityIdentifier("code")
    }
    problem
    Button(model.busy ? "Checking…" : "Check code") { Task { await model.check() } }
      .buttonStyle(.primary).disabled(!model.canCheck)
  }

  @ViewBuilder private var problem: some View {
    if model.codeDead, let error = model.error { AlertBanner(error) } else { ErrorText(model.error) }
  }

  @ViewBuilder private func credentials(_ info: JoinInfo) -> some View {
    Text("\(info.groupName) is inviting you").font(Theme.headlineSmall)
    Text("Choose a username and password. The account is yours from the start: the group cannot read your letters, and nobody can reset your password for you.\(info.expiresAt.map { " This code is good until \(Format.long($0))." } ?? "")").font(Theme.bodyLarge)
    AlertBanner(
      app.container.modes.mode == .e2e
        ? "Your password protects your encryption key. No one, not this site and not your group, can read your letters without it. After this step you will get a recovery code: it is the only way back in if you forget the password."
        : "There is no \"email me a reset link\". Keep your password somewhere safe; if you lose it, a superadmin has to help you."
    )
    LabeledField(label: "Username", hint: "3 to 16 characters") {
      TextField("", text: $model.username).textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
        .accessibilityIdentifier("join-username")
    }
    PasswordField(label: "Password", text: $model.password, show: $model.showPassword, hint: PasswordRules.lengthHint, isNew: true)
    PasswordStrengthMeter(password: model.password)
    let mismatch = !model.confirm.isEmpty && !model.passwordsMatch
    PasswordField(label: "Confirm password", text: $model.confirm, show: $model.showPassword, hint: mismatch ? "Passwords do not match." : nil, isError: mismatch, isNew: true, showsToggle: false)
    LabeledField(label: "Your name (optional)", hint: "What the group sees beside your letters, if you want a name there.") {
      TextField("", text: $model.name).textContentType(.name)
    }
    LabeledField(label: "Email (optional)") {
      TextField("", text: $model.email).textContentType(.emailAddress).keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
    }
    CheckboxRow(text: "I understand that a lost password cannot be reset by email.", isOn: $model.understood)
    problem
    Button(model.busy ? "Joining… this takes a few seconds" : "Join") { Task { await model.join() } }
      .buttonStyle(.primary).disabled(!model.canJoin).accessibilityIdentifier("join-submit")
    Button("Use a different code") { model.startOver() }.buttonStyle(.link)
      .onChange(of: model.username + model.password + model.confirm + model.email + model.name) { model.edited() }
  }
}
