import ABCCore
import Observation
import SwiftUI

@MainActor @Observable
final class ChangePasswordModel {
  var current = ""
  var new = ""
  var confirm = ""
  var show = false
  private(set) var busy = false
  private(set) var error: String?

  @ObservationIgnored private let app: AppModel
  init(app: AppModel) { self.app = app }

  var matches: Bool { new == confirm }
  var canSubmit: Bool { !busy && !current.isEmpty && new.count >= 7 && matches && new != current }

  func edited() { error = nil }

  func submit() async {
    guard canSubmit else { return }
    busy = true; error = nil
    defer { busy = false }
    do {
      try await app.sessions.changePassword(current: current, new: new)
      app.pop()
      app.show("Password changed. Other devices were signed out.")
    } catch {
      let e = AppError.from(error)
      self.error = e == .network ? "Can't reach the server. Your password has not changed." : e.userMessage ?? "Could not change the password."
    }
  }
}

struct ChangePasswordView: View {
  @State private var model: ChangePasswordModel

  init(app: AppModel) { _model = State(initialValue: ChangePasswordModel(app: app)) }

  var body: some View {
    Screen(spacing: 14, horizontal: 24) {
      Text("Changing your password signs out every other device. This one stays signed in.").font(Theme.bodyLarge)
      PasswordField(label: "Current password", text: $model.current, show: $model.show).accessibilityIdentifier("pw-current")
      PasswordField(label: "New password", text: $model.new, show: $model.show, hint: "At least 7 characters, different from the current one", isNew: true, showsToggle: false)
        .accessibilityIdentifier("pw-new")
      let mismatch = !model.confirm.isEmpty && !model.matches
      PasswordField(label: "Confirm new password", text: $model.confirm, show: $model.show, hint: mismatch ? "Passwords do not match." : nil, isError: mismatch, isNew: true, showsToggle: false)
        .accessibilityIdentifier("pw-confirm")
      ErrorText(model.error)
      Button(model.busy ? "Changing…" : "Change password") { Task { await model.submit() } }
        .buttonStyle(.primary).disabled(!model.canSubmit).accessibilityIdentifier("pw-submit")
    }
    .disabled(model.busy)
    .onChange(of: model.current + model.new + model.confirm) { model.edited() }
    .navigationTitle("Change password")
    .navigationBarTitleDisplayMode(.inline)
  }
}
