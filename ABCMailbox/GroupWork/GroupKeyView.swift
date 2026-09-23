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
          Button("Group key") { app.push(.groupKey) }.buttonStyle(.link)
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
      case .groupNotActive:
        // Nothing to set up, and nothing to offer: every group key endpoint refuses this group until an admin activates it.
        notice("Your group is not active yet", GroupKeyState.groupNotActiveText) {
          Button("Check again") { Task { await app.container.group.refreshKeyState() } }.buttonStyle(.outline)
        }
      case .notHeld:
        notice(
          "You have not been given the group key yet",
          "Until the group admin in charge of the key hands it to you, letters sent to your group stay locked on this phone. Ask them to open Inbox, Group key, and choose your name."
        ) {
          HStack(spacing: 20) {
            Button("Check again") { Task { await app.container.group.refreshKeyState() } }.buttonStyle(.outline)
            Button("Group key") { app.push(.groupKey) }.buttonStyle(.link)
          }
        }
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
      if case .ready(let key) = app.container.keyring.state, key.isOwner {
        app.show("The group key is set up, and you are the group-owner admin. Hand it to the other group admins so they can read letters too.")
      } else {
        app.show("The group key is set up. Hand it to the other group admins so they can read letters too.")
      }
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

/// Who in the group can read its letters, who owns the key, and, for the owner, handing it on (API PR #115).
struct GroupKeyView: View {
  let app: AppModel
  @State private var roster: Loadable<GroupRoster> = .loading
  @State private var busyMemberId: Int?
  @State private var error: String?
  @State private var confirmStop: GroupMember?
  @State private var confirmOwner: GroupMember?

  var body: some View {
    LoadableView(state: roster, retry: { Task { await load() } }) { roster in
      Screen(spacing: 0, horizontal: 0) {
        VStack(alignment: .leading, spacing: 8) {
          Text(ownerLine(roster)).font(Theme.bodyLarge)
          AlertBanner("Every holder of the group key can read every letter the group mails, and every reply it records. Hand it only to people the group trusts with that.")
          Text("Each group admin holds their own sealed copy of the group key, so nobody shares a password. A group admin who holds the key can read and print every letter the group mails.").font(Theme.bodyMedium)
          if roster.iAmOwner {
            Muted("Taking a group admin off this list stops new copies being given to them. It cannot take back a copy their phone has already opened: if someone should lose access for good, rotate the group key on the website.")
          }
          ErrorText(error)
        }
        .padding(20)
        Divider().overlay(Theme.rule)
        ForEach(roster.members) { member in
          row(member, roster: roster)
          Divider().overlay(Theme.rule)
        }
      }
    }
    .navigationTitle("Group key")
    .navigationBarTitleDisplayMode(.inline)
    .task { if roster.value == nil { await load() } }
    .confirmationDialog(confirmStop.map { "Stop handing the key to \($0.name)?" } ?? "", isPresented: Binding(get: { confirmStop != nil }, set: { if !$0 { confirmStop = nil } }), titleVisibility: .visible) {
      Button("Stop", role: .destructive) { if let m = confirmStop { Task { await stop(m) } } }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("They will not get the group key on their next sign-in. A phone that already opened it keeps it until the group key is rotated.")
    }
    .confirmationDialog(confirmOwner.map { "Make \($0.name) the group-owner admin?" } ?? "", isPresented: Binding(get: { confirmOwner != nil }, set: { if !$0 { confirmOwner = nil } }), titleVisibility: .visible) {
      Button("Make them the owner") { if let m = confirmOwner { Task { await makeOwner(m) } } }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("You stop being the owner: from then on only they can hand the group key out, take it back, or pass the role on. A superadmin can move it again if need be.")
    }
  }

  private func ownerLine(_ roster: GroupRoster) -> String {
    if roster.iAmOwner, roster.ownerId != nil { return "You are the group-owner admin: only you can hand the group key out, take it back, or pass this role on." }
    if let owner = roster.owner { return "\(owner.name) is the group-owner admin. Only they can hand the group key out or take it back." }
    return "This group has no group-owner admin yet. The first group admin to set up the key becomes it."
  }

  private func load() async {
    let fresh: Loadable<GroupRoster> = await .from { try await app.container.group.roster() }
    if fresh.value != nil || roster.value == nil { roster = fresh }
  }

  private func hand(_ member: GroupMember) async {
    await change(member, done: "\(member.name) can now read the group's letters, from their next sign-in or refresh.") { try await app.container.group.handKey(to: member.id) }
  }

  private func stop(_ member: GroupMember) async {
    await change(member, done: "\(member.name) will no longer be handed the group key.") { try await app.container.group.stopHandingKey(to: member.id) }
  }

  private func makeOwner(_ member: GroupMember) async {
    await change(member, done: "\(member.name) is now the group-owner admin.") { try await app.container.group.makeOwner(member) }
  }

  private func change(_ member: GroupMember, done: String, _ call: () async throws -> Void) async {
    guard busyMemberId == nil else { return }
    busyMemberId = member.id; error = nil
    defer { busyMemberId = nil }
    do {
      try await call()
      app.show(done)
      await load()
      await app.refreshMembersWaiting() // the Inbox's waiting notice: the old owner loses it, the new one gets it
    } catch {
      self.error = AppError.from(error).userMessage ?? "That did not work. Please try again."
    }
  }

  /// A row names the group admin and where they stand. The controls are the owner's alone; everyone else reads a list.
  private func row(_ member: GroupMember, roster: GroupRoster) -> some View {
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 8) {
          Text(member.name + (member.isMe ? " (you)" : "")).font(Theme.titleMedium)
          if member.isOwner { Tag(text: "Group-owner admin") }
        }
        Muted(standing(member), font: Theme.caption)
      }
      Spacer()
      if roster.iAmOwner, !member.isMe {
        let busy = busyMemberId == member.id
        if member.holdsGroupKey {
          HStack(spacing: 16) {
            // Only beside a holder: an owner who did not hold the key could hand it to nobody (docs/DECISIONS.md).
            Button("Make owner") { confirmOwner = member }.buttonStyle(.link).disabled(busyMemberId != nil).accessibilityIdentifier("makeOwner")
            Button("Stop") { confirmStop = member }.buttonStyle(.link).disabled(busyMemberId != nil)
          }
        } else if member.hasOwnKey {
          Button(busy ? "Sealing…" : "Hand key") { Task { await hand(member) } }.buttonStyle(.primaryCompact).disabled(busyMemberId != nil)
        }
      }
    }
    .padding(.horizontal, 20).padding(.vertical, 12)
  }

  private func standing(_ member: GroupMember) -> String {
    if member.holdsGroupKey { return "Holds the group key" }
    if !member.hasOwnKey { return "Has not signed in yet, so there is nothing to seal the key to" }
    if member.isWaiting { return "\(member.name) is waiting for the group key" }
    return "Cannot read the group's letters yet"
  }
}
