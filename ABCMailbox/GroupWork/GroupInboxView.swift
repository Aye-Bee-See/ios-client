import ABCCore
import SwiftUI

/// What a group member sees in place of a writer's inbox, after `inbox-org.html`:
/// the letters waiting to be printed and mailed, the conversations the group can
/// see, and the writers it looks after.
struct GroupInboxView: View {
  let app: AppModel
  let user: SessionUser
  @State private var tab = 0

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Where this member stands with the group key matters once letters are encrypted. Before the
      // switch the server reads for everyone, and the key set-up goes on underneath without a word.
      if app.container.modes.mode == .e2e { GroupKeyBanner(app: app) }
      MembersWaitingNotice(app: app)
      Picker("Section", selection: $tab) {
        Text("To print").tag(0)
        Text("Conversations").tag(1)
        Text("Writers").tag(2)
      }
      .pickerStyle(.segmented)
      .padding(.horizontal, 20).padding(.bottom, 8)

      // When the group key opens, letters that were locked become readable: rebuilding the
      // section under a new identity makes it load again.
      Group {
        switch tab {
        case 0: QueueTab(app: app, groupId: user.chapterId)
        case 1: ConversationsView(app: app, name: user.displayName, canStartLetter: false)
        default: WritersTab(app: app)
        }
      }
      .id(app.container.keyring.state.isReady)
    }
  }
}

/// What the print queue can show: one status at a time, or the queued letters that are held (API PR #106).
private enum QueueFilter: Hashable {
  case status(LetterStatus)
  case held
}

private let queueFilters: [(value: QueueFilter, label: String)] = [(.status(.queued), "Queued"), (.held, "Held"), (.status(.printed), "Printed"), (.status(.mailed), "Mailed"), (.status(.returned), "Returned")]

/// The print queue: letters this group relays, one status at a time.
private struct QueueTab: View {
  let app: AppModel
  let groupId: Int?
  @State private var filter: QueueFilter? = .status(.queued)
  @State private var loader: PagedLoader<QueueItem>

  init(app: AppModel, groupId: Int?) {
    self.app = app
    self.groupId = groupId
    _loader = State(initialValue: PagedLoader(fetch: Self.fetch(app, groupId, .status(.queued))))
  }

  private static func fetch(_ app: AppModel, _ groupId: Int?, _ filter: QueueFilter) -> (Int, Int) async throws -> ABCCore.Page<QueueItem> {
    let group = app.container.group
    return { page, size in
      guard let groupId else { return ABCCore.Page(items: [], total: 0, page: 1, pageSize: size) }
      switch filter {
      case .status(let status): return try await group.queue(groupId: groupId, status: status, page: page, pageSize: size)
      case .held: return try await group.held(groupId: groupId, page: page, pageSize: size)
      }
    }
  }

  var body: some View {
    if groupId == nil {
      // The API would answer 403 and explain, but there is nothing to ask for.
      Text("This account is not in a group yet. A network admin has to set your group before you can see its letters.").font(Theme.bodyLarge).padding(20)
    } else {
      PagedList(loader: loader, emptyText: emptyText) {
        ChipRow(options: queueFilters, selected: $filter, showAll: false).padding(.horizontal, 20).padding(.vertical, 8)
      } row: { q in
        QueueRow(item: q) { app.push(.letterWork(messageId: q.letter.id)) }
      }
      .onAppear { Task { await loader.refresh() } }
      .onChange(of: filter) {
        let chosen = filter ?? .status(.queued)
        Task { await loader.reset(fetch: Self.fetch(app, groupId, chosen)) }
      }
    }
  }

  private var emptyText: String {
    switch filter ?? .status(.queued) {
    case .status(.queued): return "Nothing is waiting to be printed."
    case .held: return "No letter is held. A letter is held when the person it is for was moved or freed after it was written."
    case .status(.printed): return "Nothing is printed and waiting for the post."
    case .status(.returned): return "No letter has come back."
    default: return "No mailed letters to show."
    }
  }
}

private struct QueueRow: View {
  let item: QueueItem
  let action: () -> Void

  private var heldWord: String {
    switch item.letter.heldReason {
    case .prisonerFree: return "they have been released"
    case .chooseRelay: return "moved; the writer has to choose who mails it"
    case .resealNeeded: return "moved; the writer has to send it again"
    default: return "open it to see why"
    }
  }

  var body: some View {
    let letter = item.letter
    let pages = estimatePages(characters: letter.body.count)
    let facts: [String?] = [
      letter.createdAt.map { "Written \(Format.short($0))" },
      "~\(Format.plural(pages, "page"))",
      letter.attachments.isEmpty ? nil : Format.plural(letter.attachments.count, "file"),
    ]
    RecordRow(
      title: item.prisoner?.name ?? "Prisoner #\(letter.prisonerId ?? 0)",
      secondary: item.prisoner?.facility.map { $0.name + ($0.country.map { ", \($0)" } ?? "") },
      subtitle: facts.compactMap { $0 }.joined(separator: " · "),
      notice: letter.isHeld ? "Held: \(heldWord)" : letter.status == .returned ? "Came back: \((letter.returnReason ?? .unknown).choice.lowercased())" : letter.relayNote.map { "Note: \($0)" }, action: action
    )
  }
}

private struct WritersTab: View {
  let app: AppModel
  @State private var writers: Loadable<[ManagedWriter]> = .loading

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 0) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Anonymous writer").font(Theme.titleMedium)
          Muted("Letters with no named writer, for example from a letter writing night. They do not need an account.")
          Button("New anonymous letter") { app.push(.pickPrisoner(writerId: nil, writerName: nil)) }.buttonStyle(.link)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        Divider().overlay(Theme.rule)

        switch writers {
        case .loading: LoadingBox()
        case .failed(let error): ErrorBox(error: error) { Task { await load() } }
        case .loaded(let list):
          if list.isEmpty { Muted("No managed writers yet.", font: Theme.bodyLarge).padding(20) }
          ForEach(list) { w in
            row(w)
            Divider().overlay(Theme.rule)
          }
        }
        Button("Add a writer") { app.push(.addWriter) }.buttonStyle(.primaryCompact).padding(20)
      }
      .frame(maxWidth: 700, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
    .refreshable { await load() }
    .background(Theme.paper)
    .onAppear { Task { await load() } }
  }

  private func load() async {
    let fresh: Loadable<[ManagedWriter]> = await .from { try await app.container.group.writers() }
    if fresh.value != nil || writers.value == nil { writers = fresh }
  }

  private func row(_ w: ManagedWriter) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(w.name).font(Theme.titleMedium)
      if let note = w.note { Muted(note) }
      Text(w.hasLiveToken ? "Claim token pending, expires \(w.tokenExpiresAt.map(Format.short) ?? "")" : "Unclaimed, no token")
        .font(Theme.label).foregroundStyle(w.hasLiveToken ? Theme.red : Theme.inkMuted)
      HStack(spacing: 20) {
        Button("New letter") { app.push(.pickPrisoner(writerId: w.id, writerName: w.name)) }.buttonStyle(.link)
        Button(w.hasLiveToken ? "Handoff token" : "Hand off account") { app.push(.handoff(writerId: w.id, writerName: w.name)) }.buttonStyle(.link)
      }
    }
    .padding(.horizontal, 20).padding(.vertical, 12)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// Members who have keys of their own and not the group's. In either mode: after the switch they
/// cannot read the group's letters until someone does this.
private struct MembersWaitingNotice: View {
  let app: AppModel
  @State private var busy = false

  var body: some View {
    let waiting = app.membersWaiting
    if !waiting.isEmpty {
      let names = waiting.map(\.name).formatted(.list(type: .and))
      VStack(alignment: .leading, spacing: 8) {
        Text(waiting.count == 1 ? "\(names) is waiting for the group key" : "\(names) are waiting for the group key").font(Theme.titleMedium)
        Text("Handing it over lets them read and print the group's letters once letters are encrypted. Only do this for people who are really in your group.").font(Theme.bodyMedium)
        HStack(spacing: 20) {
          Button(busy ? "Sealing…" : "Hand it over") {
            Task { busy = true; await app.handKeyToWaitingMembers(); busy = false }
          }
          .buttonStyle(.primaryCompact).disabled(busy)
          Button("Members") { app.push(.groupKey) }.buttonStyle(.link)
        }
      }
      .padding(16).frame(maxWidth: .infinity, alignment: .leading)
      .background(Theme.redWash, in: RoundedRectangle(cornerRadius: 8))
      .padding(.horizontal, 20).padding(.vertical, 8)
    }
  }
}
