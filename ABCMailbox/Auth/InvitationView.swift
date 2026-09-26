import ABCCore
import Observation
import SwiftUI

/// Accepting an invitation: how a group admin comes into being. In end-to-end mode nobody can make an account for
/// someone else, so this is the only way in. `member` joins the inviting group; `group` founds a new group, which
/// usually waits for an admin before it can act. The account's keypair is made on this phone, as a join makes it,
/// and the group's own key is made after the sign-in (`AppModel.setUpKeys`) where the group has none.
@MainActor @Observable
final class InvitationModel {
  var token: String
  var username = ""
  var password = ""
  var confirm = ""
  var email = ""
  var name = ""
  var group = NewGroupProfile()
  var showPassword = false
  var understood = false
  private(set) var info: InvitationInfo?
  private(set) var busy = false
  private(set) var error: String?
  /// True when the invitation was refused as used, expired, withdrawn or its group inactive: show the "ask again" state.
  private(set) var tokenDead = false

  @ObservationIgnored private let app: AppModel
  @ObservationIgnored private let arrivedWith: String?

  init(app: AppModel, token: String?) {
    self.app = app
    self.arrivedWith = token
    self.token = token.map(InvitationToken.pretty) ?? ""
  }

  var passwordsMatch: Bool { password == confirm }
  var canCheck: Bool { !busy && !token.trimmingCharacters(in: .whitespaces).isEmpty }
  var canAccept: Bool { !busy && info != nil && missing == nil }

  /// The first thing the form still needs, as a sentence for under the disabled button.
  var missing: String? {
    if let info, info.kind == .group {
      if info.groupFields.contains("name"), group.name.trimmingCharacters(in: .whitespaces).isEmpty { return "Give your group a name." }
      if info.groupFields.contains("location"), group.city.trimmingCharacters(in: .whitespaces).isEmpty { return "Say which city your group is in." }
    }
    return NewAccountForm.missing(username: username, password: password, confirm: confirm, understood: understood)
  }

  func edited() { error = nil }

  /// Sent here from the invite code box, with a token that already has the right shape: check it straight away.
  func checkIfArrived() async {
    if let arrivedWith, info == nil, !busy, InvitationToken.isWellFormed(arrivedWith) { await check() }
  }

  func startOver() {
    token = ""
    username = ""; password = ""; confirm = ""; email = ""; name = ""; group = NewGroupProfile(); understood = false
    info = nil; error = nil; tokenDead = false
  }

  func check() async {
    let typed = token
    if let problem = InvitationToken.problem(typed) { error = problem; return }
    busy = true; error = nil; tokenDead = false
    defer { busy = false }
    do {
      let found = try await app.sessions.invitationInfo(token: InviteCode.normalise(typed))
      token = InvitationToken.pretty(typed)
      if found.kind == .group, group.name.isEmpty { group.name = found.inviteeName ?? "" }
      info = found
    } catch {
      fail(.from(error))
    }
  }

  func accept() async {
    guard canAccept, let info else { return }
    busy = true; error = nil
    defer { busy = false }
    do {
      let accepted = try await app.sessions.acceptInvitation(
        token: InviteCode.normalise(token), info: info, username: username, password: password,
        email: email, name: name, penName: nil, group: info.kind == .group ? group : nil
      )
      password = ""; confirm = ""
      app.authFinished(
        toast: accepted.waitsForReview
          ? "Welcome. \(accepted.groupName) is waiting for an admin to approve it; until then you can sign in but not act."
          : "Welcome to \(accepted.groupName). You are signed in.",
        goToInbox: true
      )
    } catch {
      fail(.from(error))
    }
  }

  private func fail(_ e: AppError) {
    tokenDead = e.isGone
    switch e {
    case .notFound: error = "That invitation is not one the network issued. Check it against what you were given."
    case .gone(_, condition: "accepted"): error = "This invitation has already been used. If that was you, sign in with the username and password you chose. If not, ask whoever invited you."
    case .gone(_, condition: "expired"): error = "This invitation has expired. Ask whoever invited you to renew it; that gives you a fresh one."
    case .gone(_, condition: "revoked"): error = "This invitation was withdrawn. Ask whoever invited you."
    case .gone(_, condition: "inactive"): error = "The group behind this invitation is not active on the network right now, so its invitation cannot be used. Ask them what to do."
    case .gone: error = "This invitation can no longer be used. Ask whoever invited you for a new one."
    case .network: error = "Can't reach the server. Check your connection and try again."
    default: error = e.userMessage ?? "Something went wrong. Please try again."
    }
  }
}

struct InvitationView: View {
  @State private var model: InvitationModel
  private let app: AppModel

  init(app: AppModel, token: String?) {
    self.app = app
    _model = State(initialValue: InvitationModel(app: app, token: token))
  }

  var body: some View {
    Screen(spacing: 14, horizontal: 24) {
      if let info = model.info { form(info) } else { tokenEntry }
    }
    .disabled(model.busy)
    .navigationTitle("Accept an invitation")
    .navigationBarTitleDisplayMode(.inline)
    .task { await model.checkIfArrived() }
  }

  @ViewBuilder private var tokenEntry: some View {
    Text("An invitation makes you a group admin: of the group that invited you, or of a new group it vouches for. It was handed to you by someone you know; the site never sends one.").font(Theme.bodyLarge)
    LabeledField(label: "Invitation", hint: "24 letters and digits. Dashes, spaces and lower case are fine.") {
      TextField("XXXX-XXXX-XXXX-XXXX-XXXX-XXXX", text: $model.token)
        .font(Theme.mono)
        .textInputAutocapitalization(.characters).autocorrectionDisabled().keyboardType(.asciiCapable)
        .submitLabel(.done).onSubmit { Task { await model.check() } }
        .accessibilityIdentifier("invitation-token")
    }
    problem
    Button(model.busy ? "Checking…" : "Check invitation") { Task { await model.check() } }
      .buttonStyle(.primary).disabled(!model.canCheck)
  }

  @ViewBuilder private var problem: some View {
    if model.tokenDead, let error = model.error { AlertBanner(error) } else { ErrorText(model.error) }
  }

  @ViewBuilder private func form(_ info: InvitationInfo) -> some View {
    let until = info.expiresAt.map { " This invitation is good until \(Format.long($0))." } ?? ""
    switch info.kind {
    case .member:
      Text("\(info.groupName ?? "A group") is inviting you to join as a group admin").font(Theme.headlineSmall)
      Text("You will print and mail your group's letters and record the replies. The account is yours: nobody can reset your password for you.\(until)").font(Theme.bodyLarge)
    case .group:
      Text(info.groupName.map { "\($0) is inviting your group to join the network" } ?? "Your group is invited to join the network").font(Theme.headlineSmall)
      Text("You will be your group's first admin\(info.groupName.map { ", and \($0) vouches for you" } ?? ""). The account is yours: nobody can reset your password for you.\(until)").font(Theme.bodyLarge)
      if info.waitsForReview {
        AlertBanner("An admin approves new groups before they can act. You can sign in meanwhile; your group appears in the directory and can relay letters once it is approved.")
      }
      groupFields(info)
    }
    AlertBanner(
      app.container.modes.mode == .e2e
        ? "Your password protects your encryption key, and through it your group's letters. No one, not this site and not another group, can read them without it. After this step you will get a recovery code: it is the only way back in if you forget the password."
        : "There is no \"email me a reset link\". Keep your password somewhere safe; if you lose it, a superadmin has to help you."
    )
    SectionTitle("Your account")
    LabeledField(label: "Username", hint: "3 to 16 characters", isError: NewAccountForm.usernameTooLong(model.username)) {
      TextField("", text: $model.username).textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
        .accessibilityIdentifier("invitation-username")
    }
    PasswordField(label: "Password", text: $model.password, show: $model.showPassword, hint: PasswordRules.lengthHint, isNew: true)
    PasswordStrengthMeter(password: model.password)
    let mismatch = !model.confirm.isEmpty && !model.passwordsMatch
    PasswordField(label: "Confirm password", text: $model.confirm, show: $model.showPassword, hint: mismatch ? "Passwords do not match." : nil, isError: mismatch, isNew: true, showsToggle: false)
    LabeledField(label: "Your name (optional)", hint: "What the other admins of your group see.") {
      TextField("", text: $model.name).textContentType(.name)
    }
    LabeledField(label: "Email (optional)") {
      TextField("", text: $model.email).textContentType(.emailAddress).keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
    }
    CheckboxRow(text: "I understand that a lost password cannot be reset by email.", isOn: $model.understood)
    problem
    Button(model.busy ? "Accepting… this takes a few seconds" : "Accept invitation") { Task { await model.accept() } }
      .buttonStyle(.primary).disabled(!model.canAccept).accessibilityIdentifier("invitation-submit")
    if !model.busy, model.error == nil, let missing = model.missing { Muted(missing) }
    Button("Use a different invitation") { model.startOver() }.buttonStyle(.link)
      .onChange(of: [model.username, model.password, model.confirm, model.email, model.name, model.group.name, model.group.city, model.group.country, model.group.about, model.group.website, model.group.email]) { model.edited() }
  }

  /// Only what the invitation lets the new group say about itself; the rest is an admin's to set.
  @ViewBuilder private func groupFields(_ info: InvitationInfo) -> some View {
    SectionTitle("Your group")
    if info.groupFields.contains("name") {
      LabeledField(label: "Group name") { TextField("", text: $model.group.name).textContentType(.organizationName) }
    }
    if info.groupFields.contains("location") {
      LabeledField(label: "City", hint: "Where the group is. Writers find groups near a facility by this.") { TextField("", text: $model.group.city).textContentType(.addressCity) }
    }
    if info.groupFields.contains("country") {
      LabeledField(label: "Country (optional)") { TextField("", text: $model.group.country).textContentType(.countryName) }
    }
    if info.groupFields.contains("about") {
      FieldLabel("About the group (optional)")
      TextBox(text: $model.group.about, placeholder: "What the group does, for the directory.", minHeight: 100)
    }
    if info.groupFields.contains("website") {
      LabeledField(label: "Website (optional)") {
        TextField("", text: $model.group.website).textContentType(.URL).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
      }
    }
    if info.groupFields.contains("email") {
      LabeledField(label: "Group email (optional)", hint: "Public, in the directory.") {
        TextField("", text: $model.group.email).keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
      }
    }
  }
}
