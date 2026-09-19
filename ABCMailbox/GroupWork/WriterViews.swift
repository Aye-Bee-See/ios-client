import ABCCore
import ABCCrypto
import SwiftUI
import UIKit

/// After `create-writer.html`.
struct AddWriterView: View {
  let app: AppModel
  @State private var name = ""
  @State private var email = ""
  @State private var note = ""
  @State private var busy = false
  @State private var error: String?

  private var canSubmit: Bool { !busy && (3...32).contains(name.trimmingCharacters(in: .whitespaces).count) }

  var body: some View {
    Screen(horizontal: 24) {
      Text("Creates an account in your group's care. The writer can claim it and take independent control at any time, using a handoff token you generate later.").font(Theme.bodyLarge)
      Muted("Anonymous letters do not need an account. Use this only to follow one person's correspondence over time.")
      LabeledField(label: "Name", hint: "Whatever they go by at your events. 3 to 32 characters. Not verified, not unique.") {
        TextField("", text: $name).textContentType(.name).accessibilityIdentifier("writer-name")
      }
      LabeledField(label: "Email (optional)") {
        TextField("", text: $email).textContentType(.emailAddress).keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
      }
      LabeledField(label: "Internal note (optional)", hint: "Only your group sees this. Never shown to the writer.") {
        TextField("", text: $note, axis: .vertical).lineLimit(2...5)
      }
      ErrorText(error)
      Button("Add writer and start a letter") { Task { await submit(thenWrite: true) } }.buttonStyle(.primary).disabled(!canSubmit)
      Button(busy ? "Adding…" : "Add writer") { Task { await submit(thenWrite: false) } }.buttonStyle(.outlineWide).disabled(!canSubmit).accessibilityIdentifier("writer-add")
    }
    .disabled(busy)
    .onChange(of: name + email + note) { error = nil }
    .navigationTitle("Add a writer")
    .navigationBarTitleDisplayMode(.inline)
  }

  private func submit(thenWrite: Bool) async {
    guard canSubmit else { return }
    busy = true; error = nil
    defer { busy = false }
    do {
      let writer = try await app.container.group.addWriter(name: name, email: email, note: note)
      if thenWrite { app.replaceTop(with: .pickPrisoner(writerId: writer.id, writerName: writer.name)) } else {
        app.pop()
        app.show("\(writer.name) added.")
      }
    } catch {
      self.error = AppError.from(error).userMessage ?? "Could not add the writer."
    }
  }
}

/// After `handoff.html`, with the copy corrected to what the API does: on claim
/// the group keeps the letters it relayed (it needs them for records and
/// reprints) and loses the rest of the writer's threads and the account.
/// The claim token is shown once, here, and is never stored on the phone.
struct HandoffView: View {
  let app: AppModel
  let writerId: Int
  let writerName: String
  @State private var token: IssuedToken?
  @State private var busy = false
  @State private var revoked = false
  @State private var copied = false
  @State private var error: String?

  var body: some View {
    Screen(horizontal: 24) {
      Text("Writer: \(writerName)").font(Theme.titleLarge)
      Text("A one-time claim token lets \(writerName) set their own username and password and take independent control of their correspondence.").font(Theme.bodyLarge)
      ForEach([
        "Once claimed, they no longer appear among your group's writers, and you can no longer write as them.",
        "Your group keeps the letters it relayed, for records and reprints. It loses their other conversations.",
        "The token works once and lasts 72 hours. Making a new one cancels the old one.",
      ], id: \.self) { Text("• \($0)").font(Theme.bodyMedium) }

      if let token { shown(token) } else {
        if revoked { Muted("The token was revoked. It can no longer be used.", font: Theme.bodyLarge) }
        Button(busy ? "Working…" : "Generate claim token") { Task { await generate() } }.buttonStyle(.primary).accessibilityIdentifier("generate")
        // This screen cannot see an earlier token, only cancel it; once that is done there is nothing left to revoke.
        if !revoked { Button("Revoke the current token") { Task { await revoke() } }.buttonStyle(.outlineWide) }
      }
      ErrorText(error)
    }
    .disabled(busy)
    .navigationTitle("Hand off account")
    .navigationBarTitleDisplayMode(.inline)
  }

  @ViewBuilder private func shown(_ token: IssuedToken) -> some View {
    SecretCodeDisplay(pretty: SecretCodes.pretty(token.token)).accessibilityIdentifier("token")
    if let expires = token.expiresAt {
      Muted("Expires \(Format.long(expires)). Shown once: when you leave this screen it cannot be shown again, only replaced.")
    }
    Button(copied ? "Copied" : "Copy") {
      UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: SecretCodes.pretty(token.token)]], options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(600)])
      copied = true
    }
    .buttonStyle(.outline)
    AlertBanner("Give this to \(writerName) in person, or over a channel you both trust such as Signal. Do not email it or post it anywhere. They enter it in the app under Sign in, \"I have a claim token\".")
    Button("Regenerate (cancels this one)") { Task { await generate() } }.buttonStyle(.outlineWide)
    Button("Revoke") { Task { await revoke() } }.buttonStyle(.destructiveLink)
  }

  private func generate() async {
    busy = true; error = nil; revoked = false; copied = false
    defer { busy = false }
    do { token = try await app.container.group.issueToken(writerId: writerId) } catch {
      self.error = AppError.from(error).userMessage ?? "Could not make a token."
    }
  }

  private func revoke() async {
    busy = true; error = nil
    defer { busy = false }
    do {
      try await app.container.group.revokeToken(writerId: writerId)
      token = nil; revoked = true
    } catch {
      self.error = AppError.from(error).userMessage ?? "Could not revoke the token."
    }
  }
}
