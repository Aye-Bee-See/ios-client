import ABCCore
import Observation
import SwiftUI

/// A writer's pen name. Changes are limited (API #127): once every 90 days, and two brand-new names a rolling year,
/// because a name once used is never given to anyone else. The limits are read when the screen opens and said
/// before anyone types; the field stays closed until a change is allowed.
@MainActor @Observable
final class PenNameModel {
  let checker: PenNameChecker
  private(set) var names: PenNames?
  private(set) var loadError: AppError?
  private(set) var busy = false
  private(set) var error: String?

  @ObservationIgnored private let app: AppModel

  init(app: AppModel) {
    self.app = app
    checker = PenNameChecker(penNames: app.container.penNames)
  }

  var canChange: Bool { names?.canChange() ?? false }

  /// Out of new names this year and the name typed is not one of the account's own: nothing to send.
  var needsOldName: Bool {
    guard let names, names.newNamesLeft < 1, !checker.isBlank else { return false }
    return !names.isOwnOldName(checker.value)
  }

  var canSave: Bool {
    guard let names, canChange, !busy, !checker.isBlank, !checker.blocks, !checker.checking else { return false }
    return !names.isCurrent(checker.value) && !needsOldName
  }

  func load() async {
    do {
      names = try await app.container.penNames.names()
      loadError = nil
    } catch {
      loadError = AppError.from(error)
    }
  }

  func save() async {
    guard canSave else { return }
    busy = true; error = nil
    defer { busy = false }
    do {
      let saved = try await app.container.penNames.set(checker.value)
      checker.clear()
      await load()
      // Going back to an old name keeps its first spelling, whatever was typed: say the name as the server has it.
      app.show("Your pen name is now \(names?.current ?? saved).")
    } catch {
      let e = AppError.from(error)
      // The limits may have moved since the screen opened (another device): read them again, then say why.
      if let limit = e.penNameLimit { await load(); self.error = refusal(limit) } else {
        self.error = e == .network ? "Can't reach the server. Your pen name has not changed." : e.userMessage ?? "Could not change the pen name."
      }
    }
  }

  private func refusal(_ limit: String) -> String {
    if limit == "new_names" {
      let when = names?.newNamesWindowEnds.map { ", or a new one from \(Format.long($0))" } ?? ""
      return "You have taken your new names for this year. You can go back to a name you used before\(when)."
    }
    let when = names?.changeAllowedAt.map { " on \(Format.long($0))" } ?? " later"
    return "Your pen name changed recently, so it can change again\(when)."
  }
}

struct PenNameView: View {
  @State private var model: PenNameModel
  private let app: AppModel

  init(app: AppModel) {
    self.app = app
    _model = State(initialValue: PenNameModel(app: app))
  }

  var body: some View {
    Screen(spacing: 14, horizontal: 24) {
      Text("Your letters are signed with your pen name, and prisoners write back to it. Every name you have used stays yours for ever and is never given to anyone else, so a reply to an old name still finds you.").font(Theme.bodyLarge)
      if let names = model.names { content(names) } else if let loadError = model.loadError {
        ErrorBox(error: loadError) { Task { await model.load() } }
      } else {
        LoadingBox()
      }
    }
    .disabled(model.busy)
    .task { await model.load() }
    .navigationTitle("Pen name")
    .navigationBarTitleDisplayMode(.inline)
  }

  @ViewBuilder private func content(_ names: PenNames) -> some View {
    if let current = names.current {
      Text("Your pen name is \(current).").font(Theme.titleMedium)
    } else {
      Text("No pen name yet. Your letters are signed with your name, \(app.user?.displayName ?? "as it is on your account").").font(Theme.titleMedium)
    }
    limits(names)
    if model.canChange {
      PenNameField(checker: model.checker, label: names.current == nil ? "Pen name" : "New pen name")
      if model.needsOldName { ErrorText("This year you can only go back to a name you used before.") }
      ErrorText(model.error)
      Button(model.busy ? "Saving…" : "Save pen name") { Task { await model.save() } }
        .buttonStyle(.primary).disabled(!model.canSave).accessibilityIdentifier("pen-name-save")
    } else {
      ErrorText(model.error)
    }
    let past = names.names.filter { !$0.current }
    if !past.isEmpty {
      SectionTitle("Names you have used")
      ForEach(past) { row in
        Text(row.since.map { "\(row.name), since \(Format.long($0))" } ?? row.name).font(Theme.bodyMedium)
      }
    }
  }

  /// Said before anyone types: when a change is next possible, and how many new names are left.
  @ViewBuilder private func limits(_ names: PenNames) -> some View {
    if let allowed = names.changeAllowedAt, !names.canChange() {
      AlertBanner("You can change your pen name again on \(Format.long(allowed)). A pen name changes at most once every \(names.cooldownDays) days, so the name on letters in the post stays the one a reply comes back to.")
    } else if names.current == nil {
      Muted("Your first pen name is not a change: choosing it uses up neither limit.")
    } else {
      let left = names.newNamesLeft < 1
        ? "You have no new names left this year\(names.newNamesWindowEnds.map { "; another becomes possible on \(Format.long($0))" } ?? ""). You can still go back to a name you used before."
        : "You can take \(Format.plural(names.newNamesLeft, "new name")) more this year. Going back to a name you used before does not count."
      Muted("\(left) After a change, the next one waits \(names.cooldownDays) days.")
    }
  }
}
