import ABCCore
import Observation
import SwiftUI

/// A writer whose account was made before pen names were required (API #168) is asked for one at sign-in. The
/// letters' footer names the writer by it; without one it fell back to their display name, which may be real.
@MainActor @Observable
final class PenNameRequiredModel {
  let checker: PenNameChecker
  private(set) var busy = false
  private(set) var error: String?
  private(set) var fields = FormErrors()

  @ObservationIgnored private let app: AppModel

  init(app: AppModel) {
    self.app = app
    checker = PenNameChecker(penNames: app.container.penNames)
  }

  var canSave: Bool { !busy && !checker.isBlank && !checker.blocks && !checker.checking }

  func edited() { error = nil; fields = FormErrors() }

  func save() async {
    guard canSave else { return }
    busy = true; error = nil
    defer { busy = false }
    do {
      let saved = try await app.container.penNames.set(checker.value)
      app.penNameChosen()
      app.show("Your pen name is \(saved).")
    } catch {
      let e = AppError.from(error)
      if case .validation = e {
        fields = FormErrors(e, fields: ["penName": "pen name"])
        self.error = fields.byField.isEmpty ? fields.general : nil
      } else {
        self.error = e == .network ? "Can't reach the server. Try again when you are online." : e.userMessage ?? "Could not save the pen name."
      }
    }
  }
}

struct PenNameRequiredView: View {
  @State private var model: PenNameRequiredModel
  private let app: AppModel

  init(app: AppModel) {
    self.app = app
    _model = State(initialValue: PenNameRequiredModel(app: app))
  }

  var body: some View {
    Screen(spacing: 16, horizontal: 24) {
      Text("Choose a pen name").font(Theme.headline).padding(.top, 20)
      Text("Your letters are signed with your pen name, and a prisoner writes back to it. Every account needs one now, so that a letter never carries your real name by accident.").font(Theme.bodyLarge)
      PenNameField(checker: model.checker, label: "Pen name", serverError: model.fields.byField["penName"])
        .onChange(of: model.checker.value) { model.edited() }
      Muted("Two parts, like a real name, read best in a mail room. Choosing it now is free; later, a change waits 90 days. Every name you use stays yours.")
      ErrorText(model.error)
      Button(model.busy ? "Saving…" : "Save pen name") { Task { await model.save() } }
        .buttonStyle(.primary).disabled(!model.canSave).accessibilityIdentifier("pen-name-required-save")
      Button("Sign out") { Task { try? await app.sessions.logout(everywhere: false); app.penNameChosen() } }.buttonStyle(.link)
    }
    .disabled(model.busy)
    .background(Theme.paper.ignoresSafeArea())
  }
}
