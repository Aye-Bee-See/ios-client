import ABCCore
import Observation
import SwiftUI

/// The sign-in flow: a stack of its own, shown full screen over whichever tab asked for it.
struct AuthFlowView: View {
  @Environment(AppModel.self) private var app

  var body: some View {
    @Bindable var app = app
    NavigationStack(path: $app.authPath) {
      LoginView(app: app)
        .navigationDestination(for: AuthRoute.self) { route in
          switch route {
          case .claim(let token): ClaimView(app: app, token: token)
          case .join(let code): JoinView(app: app, code: code)
          case .recover: RecoverView(app: app)
          }
        }
    }
  }
}

/// Everything the sign-in screen shows. The view renders it and calls the event
/// functions; the model is the only thing that changes it.
@MainActor @Observable
final class LoginModel {
  var username = ""
  var password = ""
  var showPassword = false
  /// The person's explicit choice for an account from before the split scheme (API PR #117, item 23): the
  /// password itself is sent, once, by that choice. The app never sends it on its own.
  var olderAccount = false
  private(set) var submitting = false
  private(set) var error: String?

  @ObservationIgnored private let app: AppModel
  init(app: AppModel) { self.app = app }

  var canSubmit: Bool { !username.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty && !submitting }

  func edited() { error = nil }

  func submit() async {
    guard canSubmit else { return }
    submitting = true
    error = nil
    defer { submitting = false }
    do {
      try await app.sessions.login(username: username, password: password, olderAccount: olderAccount)
      password = ""; olderAccount = false
      app.authFinished()
    } catch {
      self.error = Self.message(.from(error))
    }
  }

  static func message(_ error: AppError) -> String {
    switch error {
    case .unauthorized: return "Incorrect username or password."
    case .rateLimited: return error.userMessage ?? "Too many sign-in attempts. Try again later."
    case let e where e.isSchemeRefused: return "The server would not accept this password in the form the app sends it. The app may need updating."
    case .network: return "Can't reach the server. Check your connection and try again."
    default: return error.userMessage ?? "Something went wrong. Please try again."
    }
  }
}

/// Mirrors `login.html`: username, password with a Show toggle, the note that
/// accounts come from support groups, and a pointer to recovery.
struct LoginView: View {
  @State private var model: LoginModel
  private let app: AppModel
  @FocusState private var focus: Field?
  private enum Field { case username, password }

  init(app: AppModel) {
    self.app = app
    _model = State(initialValue: LoginModel(app: app))
  }

  var body: some View {
    Screen(spacing: 16, horizontal: 24) {
      Text("Sign in").font(Theme.headline).padding(.top, 12)
      Muted("Writers and support groups sign in here.")

      LabeledField(label: "Username") {
        TextField("", text: $model.username)
          .textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
          .submitLabel(.next).focused($focus, equals: .username).onSubmit { focus = .password }
          .accessibilityIdentifier("username")
      }
      PasswordField(label: "Password", text: $model.password, show: $model.showPassword) { Task { await model.submit() } }
        .focused($focus, equals: .password).submitLabel(.go)
        .accessibilityIdentifier("password")
      ErrorText(model.error).accessibilityIdentifier("error")
      // Not a feature, an escape hatch: the API moves every account to the split scheme before it stops telling
      // accounts apart, so this is for the odd one that was not.
      CheckboxRow(text: "This is an account from before the app stopped sending passwords: sign in with the password itself. Only if a superadmin told you to.", isOn: $model.olderAccount)
        .accessibilityIdentifier("olderAccount")

      Button { Task { await model.submit() } } label: {
        if model.submitting { ProgressView().tint(Theme.paper) } else { Text("Sign in") }
      }
      .buttonStyle(.primary).disabled(!model.canSubmit).accessibilityIdentifier("submit")

      Muted("Don't have an account? A support group gives you an invite code on a slip, or sets an account up for you and hands you a claim token.").padding(.top, 8)
      Button("I have an invite code") { app.authPath.append(.join(code: nil)) }.buttonStyle(.link)
      Button("I have a claim token") { app.authPath.append(.claim(token: nil)) }.buttonStyle(.link)
      Button("Forgot your password?") { app.authPath.append(.recover) }.buttonStyle(.link)
    }
    .disabled(model.submitting)
    .onChange(of: model.username) { model.edited() }
    .onChange(of: model.password) { model.edited() }
    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Back") { app.authPresented = false } } }
    .navigationBarTitleDisplayMode(.inline)
  }
}
