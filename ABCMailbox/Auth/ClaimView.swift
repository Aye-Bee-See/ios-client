import ABCCore
import Observation
import SwiftUI

/// Two steps, after `claim.html`: check the token (so the page can say who it
/// is for), then choose credentials. The token's format is validated locally
/// first because the API allows only a few checks per hour.
@MainActor @Observable
final class ClaimModel {
  var token: String { didSet { if token != oldValue { info = nil; tokenDead = false; error = nil } } }
  var username = ""
  var password = ""
  var confirm = ""
  var email = ""
  var understood = false
  var showPassword = false
  private(set) var info: ClaimInfo?
  private(set) var busy = false
  private(set) var error: String?
  /// True when the token was refused as used or expired: show the "ask for a new one" state.
  private(set) var tokenDead = false

  @ObservationIgnored private let app: AppModel
  @ObservationIgnored private let arrivedWith: String?

  init(app: AppModel, token: String?) {
    self.app = app
    self.arrivedWith = token
    self.token = token.map(ClaimToken.pretty) ?? ""
  }

  var passwordsMatch: Bool { password == confirm }
  var canCheck: Bool { !busy && !token.trimmingCharacters(in: .whitespaces).isEmpty }
  var canClaim: Bool {
    !busy && info != nil && (3...16).contains(username.trimmingCharacters(in: .whitespaces).count) && password.count >= 7 && passwordsMatch && understood
  }

  func edited() { error = nil }

  /// Arrived by link with a token: check it straight away.
  func checkIfArrivedByLink() async {
    if let arrivedWith, info == nil, !busy, ClaimToken.isWellFormed(arrivedWith) { await check() }
  }

  func startOver() {
    token = ""
    username = ""; password = ""; confirm = ""; email = ""; understood = false
  }

  func check() async {
    let typed = token
    if let problem = ClaimToken.problem(typed) { error = problem; return }
    busy = true; error = nil; tokenDead = false
    defer { busy = false }
    do {
      let found = try await app.sessions.claimInfo(token: ClaimToken.normalise(typed))
      token = ClaimToken.pretty(typed)
      info = found
    } catch {
      fail(.from(error))
    }
  }

  func claim() async {
    guard canClaim else { return }
    busy = true; error = nil
    defer { busy = false }
    do {
      try await app.sessions.claim(token: ClaimToken.normalise(token), username: username, password: password, email: email)
      password = ""; confirm = ""
      app.authFinished(toast: "Account claimed. You are signed in.", goToInbox: true)
    } catch {
      fail(.from(error))
    }
  }

  private func fail(_ e: AppError) {
    tokenDead = e.isGone
    switch e {
    case .notFound: error = "That token is not valid. Check it against what your group gave you."
    case .gone: error = "This token has already been used or has expired. Tokens last 72 hours and work once. Ask the group that set up your account for a new one."
    case .network: error = "Can't reach the server. Check your connection and try again."
    default: error = e.userMessage ?? "Something went wrong. Please try again."
    }
  }
}

/// After `claim.html`: take over an account a support group created for you.
struct ClaimView: View {
  @State private var model: ClaimModel
  private let app: AppModel

  init(app: AppModel, token: String?) {
    self.app = app
    _model = State(initialValue: ClaimModel(app: app, token: token))
  }

  var body: some View {
    Screen(spacing: 14, horizontal: 24) {
      if let info = model.info { credentials(info) } else { tokenEntry }
    }
    .disabled(model.busy)
    .navigationTitle("Claim your account")
    .navigationBarTitleDisplayMode(.inline)
    .task { await model.checkIfArrivedByLink() }
  }

  @ViewBuilder private var tokenEntry: some View {
    Text("A support group created an account for you and gave you a one-time token. Enter it to take control of your correspondence.").font(Theme.bodyLarge)
    LabeledField(label: "Claim token", hint: "24 letters and digits. Dashes, spaces, and lower case are fine. The letters I, L, O, and U are never used.") {
      TextField("XXXX-XXXX-XXXX-XXXX-XXXX-XXXX", text: $model.token)
        .font(Theme.mono)
        .textInputAutocapitalization(.characters).autocorrectionDisabled().keyboardType(.asciiCapable)
        .submitLabel(.done).onSubmit { Task { await model.check() } }
        .accessibilityIdentifier("token")
    }
    problem
    Button(model.busy ? "Checking…" : "Check token") { Task { await model.check() } }
      .buttonStyle(.primary).disabled(!model.canCheck)
  }

  @ViewBuilder private var problem: some View {
    if model.tokenDead, let error = model.error { AlertBanner(error) } else { ErrorText(model.error) }
  }

  @ViewBuilder private func credentials(_ info: ClaimInfo) -> some View {
    Text("Set up your account").font(Theme.headlineSmall)
    Text("This account (\(info.writerName)) was created for you\(info.groupName.map { " by \($0)" } ?? ""). Choose a username and password to take independent control of your correspondence.\(info.expiresAt.map { " The token expires on \(Format.long($0))." } ?? "")")
      .font(Theme.bodyLarge)
    AlertBanner(
      app.container.modes.mode == .e2e || info.endToEnd
        ? "Your password protects your encryption key. No one, not this site and not your group, can read your letters without it. After this step you will get a recovery code: it is the only way back in if you forget the password."
        : "There is no \"email me a reset link\". Keep your password somewhere safe; if you lose it, a network admin has to help you."
    )

    LabeledField(label: "Username", hint: "3 to 16 characters") {
      TextField("", text: $model.username).textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
        .accessibilityIdentifier("claim-username")
    }
    PasswordField(label: "Password", text: $model.password, show: $model.showPassword, hint: "At least 7 characters", isNew: true)
      .accessibilityIdentifier("claim-password")
    let mismatch = !model.confirm.isEmpty && !model.passwordsMatch
    PasswordField(label: "Confirm password", text: $model.confirm, show: $model.showPassword, hint: mismatch ? "Passwords do not match." : nil, isError: mismatch, isNew: true, showsToggle: false)
      .accessibilityIdentifier("claim-confirm")
    LabeledField(label: "Email (optional)") {
      TextField("", text: $model.email).textContentType(.emailAddress).keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
    }
    CheckboxRow(text: "I understand that a lost password cannot be reset by email.", isOn: $model.understood)
      .accessibilityIdentifier("claim-understood")

    problem
    Button(model.busy ? "Claiming… this takes a few seconds" : "Claim account") { Task { await model.claim() } }
      .buttonStyle(.primary).disabled(!model.canClaim).accessibilityIdentifier("claim-submit")
    Button("Use a different token") { model.startOver() }.buttonStyle(.link)
      .onChange(of: model.username + model.password + model.confirm + model.email) { model.edited() }
  }
}
