import ABCCore
import Observation
import SwiftUI

/// The second step of a two-factor sign-in (API #173): the password was right, and a code from the authenticator
/// app, or one of the recovery codes, finishes it. The waiting sign-in lives in `SessionRepository`; this screen
/// forgets it when it is left, and stops at its expiry instead of sending a challenge that is no longer good.
@MainActor @Observable
final class TwoFactorCodeModel {
  var code = ""
  private(set) var useRecovery = false
  private(set) var busy = false
  private(set) var error: String?
  /// The challenge ran out or was used: only the way back to the password is left, so nothing loops.
  private(set) var expired = false

  @ObservationIgnored private let app: AppModel
  @ObservationIgnored private let afterRecovery: Bool

  init(app: AppModel, afterRecovery: Bool) {
    self.app = app
    self.afterRecovery = afterRecovery
  }

  var canSubmit: Bool {
    guard !busy, !expired else { return false }
    return useRecovery ? TwoFactorCode.isRecoveryCodeShaped(code) : TwoFactorCode.isWellFormed(code)
  }

  /// Typing clears the last refusal. Six digits are the whole code, so they go at once, as a code filled in from
  /// a message or a password manager would.
  func edited() async {
    error = nil
    if !useRecovery, TwoFactorCode.isWellFormed(code) { await submit() }
  }

  func toggleRecovery() {
    useRecovery.toggle()
    code = ""; error = nil
  }

  func submit() async {
    guard canSubmit else { return }
    busy = true; error = nil
    defer { busy = false }
    do {
      if useRecovery { try await app.sessions.completeTwoFactor(recoveryCode: code) } else { try await app.sessions.completeTwoFactor(code: code) }
      code = ""
      if afterRecovery { app.authFinished(toast: "Password changed. You are signed in.", goToInbox: true) } else { app.authFinished() }
    } catch {
      let e = AppError.from(error)
      switch e {
      case .unauthorized: timedOut()
      case .validation:
        self.error = useRecovery ? "That recovery code is not right, or was used already." : "That code is not right. Check the app shows this account, and type the code it shows now."
      case .rateLimited: self.error = e.userMessage ?? "Too many sign-in attempts. Try again later."
      case .network: self.error = "Can't reach the server. Check your connection and try again."
      default: self.error = e.userMessage ?? "Something went wrong. Please try again."
      }
    }
  }

  /// The clock ran out (here, or on the server): the waiting sign-in is forgotten.
  func timedOut() {
    app.sessions.cancelTwoFactor()
    expired = true
    error = "That took too long. Enter your password again."
  }

  func backToPassword() {
    app.sessions.cancelTwoFactor()
    // After a recovery the password is the new one, typed on the sign-in screen, not the recovery form again.
    if afterRecovery { app.authPath = [] } else if !app.authPath.isEmpty { app.authPath.removeLast() }
  }
}

struct TwoFactorCodeView: View {
  @State private var model: TwoFactorCodeModel
  private let app: AppModel
  private let afterRecovery: Bool
  @FocusState private var focused: Bool

  init(app: AppModel, afterRecovery: Bool) {
    self.app = app
    self.afterRecovery = afterRecovery
    _model = State(initialValue: TwoFactorCodeModel(app: app, afterRecovery: afterRecovery))
  }

  var body: some View {
    Screen(spacing: 16, horizontal: 24) {
      Text("Enter your code").font(Theme.headline).padding(.top, 12)
      if afterRecovery { AlertBanner("Your password is changed. Two-factor sign-in is on, so a code finishes signing in.") }
      if model.expired {
        AlertBanner(model.error ?? "That took too long. Enter your password again.")
        Button("Back to the password") { model.backToPassword() }.buttonStyle(.primary)
      } else {
        form
      }
    }
    .disabled(model.busy)
    .navigationTitle("Two-factor sign-in")
    .navigationBarTitleDisplayMode(.inline)
    .navigationBarBackButtonHidden()
    .onAppear { focused = true }
    // The clock: stops when the screen goes, so a forgotten sign-in never fires later.
    .task(id: app.sessions.twoFactorChallenge?.expiresAt) {
      guard let expiresAt = app.sessions.twoFactorChallenge?.expiresAt else { return }
      try? await Task.sleep(for: .seconds(max(0, expiresAt.timeIntervalSinceNow)))
      if !Task.isCancelled, !model.busy, app.sessions.twoFactorChallenge != nil { model.timedOut() }
    }
    // Left by any way at all (the back gesture included): the waiting sign-in goes with it.
    .onDisappear { app.sessions.cancelTwoFactor() }
  }

  @ViewBuilder private var form: some View {
    Text(model.useRecovery ? "Type one of the recovery codes you saved when you set it up. Each works once." : "Your password was right. Now type the six-digit code your authenticator app shows for this account.")
      .font(Theme.bodyLarge)
    if model.useRecovery {
      LabeledField(label: "Recovery code", isError: model.error != nil) {
        TextField("XXXXX-XXXXX", text: $model.code)
          .font(Theme.mono)
          .textInputAutocapitalization(.characters).autocorrectionDisabled().keyboardType(.asciiCapable)
          .focused($focused).submitLabel(.go).onSubmit { Task { await model.submit() } }
          .accessibilityIdentifier("two-factor-recovery-code")
      }
    } else {
      LabeledField(label: "Six-digit code", isError: model.error != nil) {
        TextField("123456", text: $model.code)
          .font(Theme.mono)
          .textContentType(.oneTimeCode).keyboardType(.numberPad)
          .focused($focused)
          .accessibilityIdentifier("two-factor-code")
      }
    }
    ErrorText(model.error).accessibilityIdentifier("two-factor-error")
    Button { Task { await model.submit() } } label: {
      if model.busy { Text("Signing in…") } else { Text("Sign in") }
    }
    .buttonStyle(.primary).disabled(!model.canSubmit).accessibilityIdentifier("two-factor-submit")
    Button(model.useRecovery ? "Use a code from the app instead" : "Use a recovery code instead") { model.toggleRecovery(); focused = true }
      .buttonStyle(.link).accessibilityIdentifier("two-factor-toggle")
    Button("Back to the password") { model.backToPassword() }.buttonStyle(.link)
      .onChange(of: model.code) { Task { await model.edited() } }
  }
}
