import ABCCore
import Observation
import SwiftUI

@MainActor @Observable
final class GroupNumbersModel {
  /// `.loaded(nil)`: the server is older than the counting (API PR #112), which is not a group that mailed nothing.
  private(set) var numbers: Loadable<GroupNumbers?> = .loading
  var before = ""
  private(set) var busy = false
  private(set) var error: String?

  @ObservationIgnored private let app: AppModel
  init(app: AppModel) { self.app = app }

  /// A whole number, not negative; nil while what is typed is not one.
  var typed: Int? { Int(before.trimmingCharacters(in: .whitespaces)).flatMap { $0 >= 0 ? $0 : nil } }
  var canSave: Bool { !busy && typed != nil && typed != numbers.value??.before }

  func load() async {
    numbers = await .from { try await self.app.container.group.numbers() }
    if let loaded = numbers.value ?? nil { before = String(loaded.before) }
  }

  func edited() { error = nil }

  func save() async {
    guard canSave, let typed else { return }
    busy = true; error = nil
    defer { busy = false }
    do {
      try await app.container.group.setLettersSentBefore(typed)
      app.show("Saved.")
      await load() // the total, and whether it is shown to the public, are the server's to say
    } catch {
      self.error = AppError.from(error).userMessage ?? "Could not save the number."
    }
  }
}

/// A group's numbers as its members see them (API PR #112). The site counts; the one thing a person types is
/// what the group mailed before it used the site. Nothing here offers `lettersSent` or `averageTimeDays` for editing.
struct GroupNumbersView: View {
  @State private var model: GroupNumbersModel

  init(app: AppModel) { _model = State(initialValue: GroupNumbersModel(app: app)) }

  var body: some View {
    LoadableView(state: model.numbers, retry: { Task { await model.load() } }) { numbers in
      if let numbers { content(numbers) } else {
        Screen { Muted("This server does not count a group's letters yet.", font: Theme.bodyLarge) }
      }
    }
    .navigationTitle("Your group's numbers")
    .navigationBarTitleDisplayMode(.inline)
    .task { if model.numbers.value == nil { await model.load() } }
  }

  private func content(_ n: GroupNumbers) -> some View {
    Screen(spacing: 12, horizontal: 24) {
      Text("What the directory says about how much mail \(n.groupName) handles. The site counts it; nobody types it in.").font(Theme.bodyLarge)

      SectionTitle("What the public sees")
      if n.published == nil {
        Muted("Nothing yet. A group's numbers are shown once it has mailed \(GroupNumbers.shownFrom) letters, so that a small or new group is not put on show. Yours stands at \(n.total).", font: Theme.bodyLarge)
      }
      KeyValue("Letters mailed", n.published)
      KeyValue("Usual time from written to mailed", n.averageDaysToMail.map { Format.plural($0, "day") })

      SectionTitle("How it is counted")
      KeyValue("Marked as mailed on this site", String(n.countedHere))
      let invalid = !model.before.isEmpty && model.typed == nil
      LabeledField(label: "Letters you mailed before you used this site", hint: invalid ? "A whole number that is not negative." : "A whole number, your best honest estimate. It is added to what the site counts.", isError: invalid) {
        TextField("0", text: $model.before).keyboardType(.numberPad).accessibilityIdentifier("lettersSentBefore")
      }
      ErrorText(model.error)
      Button(model.busy ? "Saving…" : "Save") { Task { await model.save() } }
        .buttonStyle(.primary).disabled(!model.canSave).accessibilityIdentifier("saveNumbers")
    }
    .disabled(model.busy)
    .onChange(of: model.before) { model.edited() }
  }
}
