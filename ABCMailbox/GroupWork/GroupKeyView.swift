import ABCCore
import SwiftUI

/// End-to-end servers only: tells a group member where they stand with the
/// group's key, above the inbox tabs. Says nothing in server mode. Each state
/// is a normal situation with a next step, so none is styled as an error.
struct GroupKeyBanner: View {
  let app: AppModel
  @State private var busy = false
  @State private var error: String?

  var body: some View {
    Group {
      switch app.container.keyring.state {
      case .notNeeded:
        EmptyView()
      case .ready(let key):
        HStack {
          Muted("End-to-end encrypted · group key open (version \(key.version))", font: Theme.label)
          Spacer()
          Button("Members") { app.push(.groupKey) }.buttonStyle(.link)
        }
        .padding(.horizontal, 20)
      case .notSetUp:
        notice(
          "Your group has no encryption key yet",
          "Letters on this server are encrypted so that only the writer and the relay group can read them. Your group needs a key of its own before anyone can send it a letter. It is made on this phone, once, and you then hand it to the other members."
        ) {
          Button(busy ? "Setting up…" : "Set up the group key") { Task { await setUp() } }.buttonStyle(.primaryCompact).disabled(busy)
          ErrorText(error)
        }
      case .notHeld:
        notice(
          "You have not been given the group key yet",
          "Until a member who holds the key hands it to you, letters sent to your group stay locked on this phone. Ask them to open Inbox, Members, and choose your name."
        ) { Button("Check again") { Task { await app.container.group.refreshKeyState() } }.buttonStyle(.outline) }
      case .locked:
        notice("Your letters are locked on this device", "Unlock them with your password; the group key opens with your own.") { EmptyView() }
      case .failed(let error):
        notice("The group key could not be checked", error.userMessage ?? "No connection to the server.") {
          Button("Try again") { Task { await app.container.group.refreshKeyState() } }.buttonStyle(.outline)
        }
      }
    }
    // Another member may have acted since this screen was last shown.
    .onAppear { if !app.container.keyring.state.isReady { Task { await app.container.group.refreshKeyState() } } }
  }

  private func setUp() async {
    guard !busy else { return }
    busy = true; error = nil
    defer { busy = false }
    do {
      try await app.container.group.setUpGroupKey()
      app.show("The group key is set up. Hand it to the other members so they can read letters too.")
    } catch {
      self.error = AppError.from(error).userMessage ?? "Could not set up the group key."
    }
  }

  private func notice<Actions: View>(_ title: String, _ body: String, @ViewBuilder actions: () -> Actions) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title).font(Theme.titleMedium)
      Text(body).font(Theme.bodyMedium)
      actions()
    }
    .padding(16).frame(maxWidth: .infinity, alignment: .leading)
    .background(Theme.redWash, in: RoundedRectangle(cornerRadius: 8))
    .padding(.horizontal, 20).padding(.vertical, 8)
  }
}

/// Who in the group can read its letters, and handing the key to those who cannot yet.
struct GroupKeyView: View {
  let app: AppModel
  @State private var members: Loadable<[GroupMember]> = .loading
  @State private var busyMemberId: Int?
  @State private var error: String?
  @State private var confirmStop: GroupMember?

  var body: some View {
    LoadableView(state: members, retry: { Task { await load() } }) { list in
      Screen(spacing: 0, horizontal: 0) {
        VStack(alignment: .leading, spacing: 8) {
          Text("Each member holds their own sealed copy of the group key, so nobody shares a password. Hand the key to a member and they can read and print the group's letters.").font(Theme.bodyMedium)
          Muted("Taking a member off this list stops new copies being given to them. It cannot take back a copy their phone has already opened: if someone should lose access for good, rotate the group key on the website.", font: Theme.caption)
          ErrorText(error)
        }
        .padding(20)
        Divider().overlay(Theme.rule)
        ForEach(list) { member in
          row(member)
          Divider().overlay(Theme.rule)
        }
      }
    }
    .navigationTitle("Group key")
    .navigationBarTitleDisplayMode(.inline)
    .task { if members.value == nil { await load() } }
    .confirmationDialog(confirmStop.map { "Stop handing the key to \($0.name)?" } ?? "", isPresented: Binding(get: { confirmStop != nil }, set: { if !$0 { confirmStop = nil } }), titleVisibility: .visible) {
      Button("Stop", role: .destructive) { if let m = confirmStop { Task { await stop(m) } } }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("They will not get the group key on their next sign-in. A phone that already opened it keeps it until the group key is rotated.")
    }
  }

  private func load() async {
    let fresh: Loadable<[GroupMember]> = await .from { try await app.container.group.members() }
    if fresh.value != nil || members.value == nil { members = fresh }
  }

  private func hand(_ member: GroupMember) async {
    await change(member, done: "\(member.name) can now read the group's letters, from their next sign-in or refresh.") { try await app.container.group.handKey(to: member.id) }
  }

  private func stop(_ member: GroupMember) async {
    await change(member, done: "\(member.name) will no longer be handed the group key.") { try await app.container.group.stopHandingKey(to: member.id) }
  }

  private func change(_ member: GroupMember, done: String, _ call: () async throws -> Void) async {
    guard busyMemberId == nil else { return }
    busyMemberId = member.id; error = nil
    defer { busyMemberId = nil }
    do {
      try await call()
      app.show(done)
      await load()
    } catch {
      self.error = AppError.from(error).userMessage ?? "That did not work. Please try again."
    }
  }

  private func row(_ member: GroupMember) -> some View {
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        Text(member.name + (member.isMe ? " (you)" : "")).font(Theme.titleMedium)
        Muted(member.holdsGroupKey ? "Holds the group key" : !member.hasOwnKey ? "Has not signed in yet, so there is nothing to seal the key to" : "Cannot read the group's letters yet", font: Theme.caption)
      }
      Spacer()
      if !member.isMe {
        let busy = busyMemberId == member.id
        if member.holdsGroupKey {
          Button("Stop") { confirmStop = member }.buttonStyle(.link).disabled(busyMemberId != nil)
        } else if member.hasOwnKey {
          Button(busy ? "Sealing…" : "Hand key") { Task { await hand(member) } }.buttonStyle(.primaryCompact).disabled(busyMemberId != nil)
        }
      }
    }
    .padding(.horizontal, 20).padding(.vertical, 12)
  }
}
