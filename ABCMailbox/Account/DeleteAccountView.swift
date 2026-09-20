import ABCCore
import Observation
import SwiftUI

@MainActor @Observable
final class DeleteAccountModel {
  var typedUsername = ""
  var password = ""
  var show = false
  /// Ticked by hand: the one guard that makes the person read the sentence that matters most.
  var understood = false
  private(set) var preview: AccountDeletionPreview?
  private(set) var busy = false
  private(set) var error: String?

  @ObservationIgnored private let app: AppModel
  let username: String
  let isGroupMember: Bool

  init(app: AppModel) {
    self.app = app
    username = app.user?.username ?? ""
    isGroupMember = app.user?.role == Role.chapter
  }

  /// Typing the username is the guard against a slip of the thumb; the password, which the server
  /// demands, is the guard against a borrowed phone. Case and stray spaces are forgiven: this proves
  /// intent, not identity.
  var usernameMatches: Bool { typedUsername.trimmingCharacters(in: .whitespaces).lowercased() == username.lowercased() }
  var blockedByGroupKey: Bool { preview?.isLastKeyHolder == true }
  var canDelete: Bool { !busy && usernameMatches && !password.isEmpty && understood && !blockedByGroupKey }

  func edited() { error = nil }

  func load() async { preview = await app.container.accountDeletion.preview() }

  func delete() async {
    guard canDelete else { return }
    busy = true; error = nil
    defer { busy = false }
    do {
      let gone = try await app.container.accountDeletion.deleteMyAccount(password: password)
      password = ""
      // Signed out now. Nothing of the account may stay on screen, and the Account tab is the honest place to land.
      app.closeEverything()
      app.tab = .account
      app.show(Self.farewell(gone))
    } catch {
      password = ""
      switch AppError.from(error) {
      case .network, .unreadable: self.error = "Can't reach the server. Nothing was deleted."
      case let e: self.error = e.userMessage ?? "The account could not be deleted. Nothing was deleted."
      }
      await load() // a refusal may be about the group key, which the notice above explains
    }
  }

  static func farewell(_ gone: DeletedAccount) -> String {
    var parts: [String] = []
    if gone.letters > 0 { parts.append(Format.plural(gone.letters, "letter")) }
    if gone.replies > 0 { parts.append(gone.replies == 1 ? "1 reply" : "\(gone.replies) replies") }
    if gone.unsentLetters > 0 { parts.append("\(Format.plural(gone.unsentLetters, "unsent letter")) on this phone") }
    return "Your account was deleted" + (parts.isEmpty ? "." : ", with \(parts.formatted(.list(type: .and))).")
  }
}

/// Deleting one's own account (API PR #104). The screen says in words what will go before it asks for
/// anything; then four things stand between a person and a mistake: typing their username, their
/// password (which the server checks), ticking "I understand this cannot be undone", and a last
/// confirmation that names the consequence again.
struct DeleteAccountView: View {
  @State private var model: DeleteAccountModel
  @State private var confirming = false
  private let app: AppModel

  init(app: AppModel) {
    self.app = app
    _model = State(initialValue: DeleteAccountModel(app: app))
  }

  var body: some View {
    Screen(spacing: 14, horizontal: 24) {
      AlertBanner("This cannot be undone. Nobody, not your group and not a network admin, can bring any of it back.")

      SectionTitle("What will be deleted")
      ForEach(whatGoes, id: \.self) { bullet($0) }

      SectionTitle("What this does not do")
      bullet("It does not recall a letter that is already printed or in the post. The prisoner will still receive it. If they write back, there will be no account for a group to record their reply on.")
      if model.isGroupMember {
        bullet("What you did for your group stays, without your name on it: letters you marked printed or mailed, invitations, changes you proposed to the directory. The letters of writers your group looks after are the group's, and stay.")
      }

      if let p = model.preview, p.isLastKeyHolder { lastKeyHolderNotice(p) } else { form }
    }
    .disabled(model.busy)
    .navigationTitle("Delete my account")
    .navigationBarTitleDisplayMode(.inline)
    .task { await model.load() }
    .onChange(of: model.typedUsername + model.password) { model.edited() }
    .confirmationDialog("Delete @\(model.username) and every letter in it?", isPresented: $confirming, titleVisibility: .visible) {
      Button("Delete everything", role: .destructive) { Task { await model.delete() } }
      Button("Keep my account", role: .cancel) {}
    } message: {
      Text("This is the last step. It cannot be undone.")
    }
  }

  private var whatGoes: [String] {
    let p = model.preview
    var lines: [String] = []
    if let n = p?.conversations, n > 0 {
      lines.append("Your \(Format.plural(n, "conversation")), with every letter you wrote in them, whatever its status, and every reply recorded for you.")
    } else {
      lines.append("Every letter you wrote, whatever its status, and every reply recorded for you, with the conversations they are in.")
    }
    lines.append("Every file attached to those letters.")
    if let n = p?.unsentLetters, n > 0 { lines.append("The \(Format.plural(n, "letter")) waiting on this phone to be sent, and your drafts. They will never be sent.") } else { lines.append("Your drafts on this phone.") }
    lines.append("The account itself. Your username is free for anyone to take, at once.")
    if p?.endToEnd == true {
      lines.append("Your encryption key. Your recovery code becomes useless: there will be nothing left for it to open.")
    } else {
      lines.append("Your encryption key and recovery code, which become useless.")
    }
    return lines
  }

  private func bullet(_ text: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text("•")
      Text(text)
    }
    .font(Theme.bodyMedium)
    .accessibilityElement(children: .combine)
  }

  @ViewBuilder private func lastKeyHolderNotice(_ p: AccountDeletionPreview) -> some View {
    SectionTitle("Not yet")
    AlertBanner("You are the only member who holds your group's key. If this account went now, nobody could ever read the group's letters again, so the server will refuse. Hand the key to another member first.")
    if p.membersWhoCouldHoldTheKey.isEmpty {
      Muted("No other member has signed in yet, so there is nobody to hand it to. Invite or wait for a second member, then come back.")
    } else {
      Muted("\(p.membersWhoCouldHoldTheKey.formatted(.list(type: .or))) could be handed it now.")
    }
    Button("Open the Group key screen") { app.push(.groupKey) }.buttonStyle(.primary)
  }

  @ViewBuilder private var form: some View {
    SectionTitle("If you are sure")
    LabeledField(label: "Type your username, \(model.username), to show you mean it", isError: !model.typedUsername.isEmpty && !model.usernameMatches) {
      TextField("", text: $model.typedUsername).textInputAutocapitalization(.never).autocorrectionDisabled()
        .accessibilityIdentifier("delete-username")
    }
    // Not offered to a password manager as a sign-in: filling it in should be a deliberate act.
    PasswordField(label: "Your password", text: $model.password, show: $model.show, hint: "Checked by the server, so that a borrowed phone is not enough.")
      .accessibilityIdentifier("delete-password")
    CheckboxRow(text: "I understand this cannot be undone.", isOn: $model.understood).accessibilityIdentifier("delete-understood")
    ErrorText(model.error)
    Button(model.busy ? "Deleting…" : "Delete my account and all my letters") { confirming = true }
      .buttonStyle(DestructiveButtonStyle()).disabled(!model.canDelete).accessibilityIdentifier("delete-submit")
    Button("Keep my account") { app.pop() }.buttonStyle(.outlineWide)
  }
}

/// The one red button in the app.
struct DestructiveButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(Theme.titleMedium)
      .foregroundStyle(.white)
      .padding(.vertical, 13).padding(.horizontal, 20)
      .frame(maxWidth: .infinity)
      .background(Theme.red.opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.35), in: RoundedRectangle(cornerRadius: 6))
  }
}
