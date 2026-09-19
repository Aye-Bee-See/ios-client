import ABCCore
import ABCCrypto
import Observation
import SwiftUI

@MainActor @Observable
final class RecoverModel {
  var username = ""
  var code = ""
  var password = ""
  var confirm = ""
  var show = false
  private(set) var busy = false
  private(set) var error: String?

  @ObservationIgnored private let app: AppModel
  init(app: AppModel) { self.app = app }

  var matches: Bool { password == confirm }
  var canSubmit: Bool { !busy && !username.trimmingCharacters(in: .whitespaces).isEmpty && !code.trimmingCharacters(in: .whitespaces).isEmpty && password.count >= 7 && matches }

  func edited() { error = nil }

  func submit() async {
    guard canSubmit else { return }
    // Check the code's shape locally: recovery starts are rate limited per username.
    guard SecretCodes.isWellFormed(code) else { error = "A recovery code has 24 letters and digits, and never I, L, O, or U."; return }
    busy = true; error = nil
    defer { busy = false }
    do {
      try await app.sessions.recover(username: username, recoveryCode: code, newPassword: password)
      password = ""; confirm = ""; code = ""
      app.authFinished(toast: "Password changed. You are signed in.", goToInbox: true)
    } catch {
      switch AppError.from(error) {
      case .notFound: self.error = "No account with that username has a recovery code."
      case .unauthorized: self.error = "Recovery was refused. Start again; each attempt is valid for ten minutes and works once."
      case .network: self.error = "Can't reach the server. Nothing has changed."
      case let e: self.error = e.userMessage ?? "Recovery failed. Please try again."
      }
    }
  }
}

/// After `forgot-password.html`, corrected for what the API offers. On an
/// end-to-end server the recovery code works: it unwraps the private key, the
/// app proves possession to the server, and a new password is set. In server
/// mode there is no self-service path and the page explains the real options.
struct RecoverView: View {
  @State private var model: RecoverModel
  private let app: AppModel

  init(app: AppModel) {
    self.app = app
    _model = State(initialValue: RecoverModel(app: app))
  }

  var body: some View {
    Screen(horizontal: 24) {
      Text("There is no reset link we can email you. That is deliberate: a server that can reset your password is a server that can get into your letters.").font(Theme.bodyLarge)

      if app.container.modes.mode == .e2e { recoveryForm } else {
        SectionTitle("If the account is your own")
        Text("Contact a network admin through the group you write with. They can confirm who you are and set a new password for you.").font(Theme.bodyMedium)
      }

      SectionTitle("If a support group set up your account and you have not claimed it yet")
      Text("Ask the group for a new claim token. Tokens last 72 hours and work once; they can make another at any time.").font(Theme.bodyMedium)
      Button("I have a claim token") { app.authPath.append(.claim(token: nil)) }.buttonStyle(.primaryCompact)
      Muted("Too many wrong sign-in attempts lock a username for 15 minutes. Waiting is sometimes all it takes.")
    }
    .disabled(model.busy)
    .navigationTitle("Forgot your password?")
    .navigationBarTitleDisplayMode(.inline)
    .task { await app.container.modes.refresh() }
  }

  @ViewBuilder private var recoveryForm: some View {
    SectionTitle("Use your recovery code")
    Text("Enter the code you saved when you set up your account, and choose a new password. Your letters stay readable: the key does not change, only the password that protects it.").font(Theme.bodyMedium)
    LabeledField(label: "Username") {
      TextField("", text: $model.username).textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
        .accessibilityIdentifier("recover-username")
    }
    LabeledField(label: "Recovery code") {
      TextField("XXXX-XXXX-XXXX-XXXX-XXXX-XXXX", text: $model.code).font(Theme.mono)
        .textInputAutocapitalization(.characters).autocorrectionDisabled().keyboardType(.asciiCapable)
        .accessibilityIdentifier("recover-code")
    }
    PasswordField(label: "New password", text: $model.password, show: $model.show, hint: "At least 7 characters", isNew: true)
      .accessibilityIdentifier("recover-password")
    PasswordField(label: "Confirm new password", text: $model.confirm, show: $model.show, isError: !model.confirm.isEmpty && !model.matches, isNew: true, showsToggle: false)
      .accessibilityIdentifier("recover-confirm")
    ErrorText(model.error)
    Button(model.busy ? "Recovering…" : "Set new password") { Task { await model.submit() } }
      .buttonStyle(.primary).disabled(!model.canSubmit).accessibilityIdentifier("recover-submit")
      .onChange(of: model.username + model.code + model.password + model.confirm) { model.edited() }
    Muted("Lost the code too? Then the letters on this account cannot be recovered by anyone. A network admin can help you start a new account.")
  }
}
