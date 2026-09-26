import ABCCore
import Observation
import SwiftUI

/// A pen name as it is typed: the shape checked at once, and the server asked a moment after typing stops whether
/// the name is free, so that the rate-limited check is not made for every character.
@MainActor @Observable
final class PenNameChecker {
  var value = ""
  private(set) var problem: String?
  private(set) var checking = false
  private(set) var check: PenNameCheck?
  private(set) var checkFailed = false

  @ObservationIgnored private let penNames: PenNameRepository
  @ObservationIgnored private var task: Task<Void, Never>?

  init(penNames: PenNameRepository) { self.penNames = penNames }

  var isBlank: Bool { value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
  /// The form must not go on with this name. An unreachable check does not block: the server checks again on submit.
  var blocks: Bool { !isBlank && (problem != nil || check?.available == false) }
  var isError: Bool { problem != nil || check?.available == false }

  /// What to say under the field, or nil for the rules.
  var message: String? {
    if isBlank { return nil }
    if let problem { return problem }
    if let check {
      if !check.available { return check.reason ?? "That name is taken." }
      return check.twoParts ? "\(check.name) is free." : "\(check.name) is free. A first and a last part, like a real name, reads better in a mail room."
    }
    return checkFailed ? "Could not check the name just now; it will be checked when you continue." : nil
  }

  func edited() {
    task?.cancel()
    check = nil; checkFailed = false; checking = false
    problem = isBlank ? nil : PenName.problem(value)
    guard !isBlank, problem == nil else { return }
    let typed = value
    task = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(400))
      guard let self, !Task.isCancelled else { return }
      checking = true
      let answer: PenNameCheck?
      do { answer = try await penNames.check(typed) } catch { answer = nil }
      // Typing went on meanwhile: this answer is about an older name, and the newer one has its own check coming.
      guard value == typed, !Task.isCancelled else { return }
      checking = false
      if let answer { check = answer } else { checkFailed = true }
    }
  }

  func clear() {
    value = ""
    edited()
  }
}

struct PenNameField: View {
  @Bindable var checker: PenNameChecker
  var label = "Pen name"

  var body: some View {
    LabeledField(label: label, hint: checker.checking ? "Checking…" : checker.message ?? PenName.rules, isError: checker.isError) {
      TextField("", text: $checker.value)
        .textInputAutocapitalization(.words).autocorrectionDisabled()
        .accessibilityIdentifier("pen-name")
    }
    .onChange(of: checker.value) { checker.edited() }
  }
}
