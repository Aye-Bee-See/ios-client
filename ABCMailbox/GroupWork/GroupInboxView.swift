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
      // A group that is not active yet is told so in either mode: it cannot print or manage writers either.
      if app.container.modes.mode == .e2e || app.container.keyring.state.isGroupNotActive { GroupKeyBanner(app: app) }
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
  // Letter nights (API PR #111): tick several letters, mark them together. All or none.
  @State private var selecting = false
  @State private var selected: Set<Int> = []
  @State private var busy = false
  @State private var confirmMailed = false

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
      Text("This account is not in a group yet. A superadmin has to set your group before you can see its letters.").font(Theme.bodyLarge).padding(20)
    } else {
      PagedList(loader: loader, emptyText: emptyText) {
        ChipRow(options: queueFilters, selected: $filter, showAll: false).padding(.horizontal, 20).padding(.vertical, 8).disabled(selecting)
        if nextStatus != nil, !selecting, loader.items.count > 1 {
          Button("Select several…") { selecting = true }.buttonStyle(.link).padding(.horizontal, 20).padding(.bottom, 4).accessibilityIdentifier("selectSeveral")
        }
      } row: { q in
        if selecting {
          // A held letter is a decision of its own, made on its own page: it cannot be ticked.
          QueueRow(item: q, tick: q.letter.isHeld ? .cannot : selected.contains(q.id) ? .on : .off) { toggle(q) }
        } else {
          QueueRow(item: q) { app.push(.letterWork(messageId: q.letter.id)) }
        }
      }
      .safeAreaInset(edge: .bottom) { if selecting { selectionBar } }
      .onAppear { Task { await loader.refresh() } }
      .onChange(of: filter) {
        let chosen = filter ?? .status(.queued)
        Task { await loader.reset(fetch: Self.fetch(app, groupId, chosen)) }
      }
      .confirmationDialog("Mark \(Format.plural(selected.count, "letter")) as mailed?", isPresented: $confirmMailed, titleVisibility: .visible) {
        Button("They are in the mail") { Task { await markSelected() } }
        Button("Not yet", role: .cancel) {}
      } message: {
        Text("Do this once the letters are actually in the mail. Their writers will see them as mailed, and it cannot be moved back.")
      }
    }
  }

  /// Where the letters of the list on screen go next, if they can be moved together at all.
  private var nextStatus: LetterStatus? {
    switch filter ?? .status(.queued) {
    case .status(.queued): return .printed
    case .status(.printed): return .mailed
    default: return nil
    }
  }

  private func toggle(_ q: QueueItem) {
    guard !q.letter.isHeld, !busy else { return }
    if selected.contains(q.id) { selected.remove(q.id) } else if selected.count < GroupRepository.batchLimit { selected.insert(q.id) } else {
      app.show("At most \(GroupRepository.batchLimit) letters can be marked at once.")
    }
  }

  private var selectionBar: some View {
    HStack(spacing: 12) {
      Button("Cancel") { selecting = false; selected = [] }.buttonStyle(.link)
      Spacer()
      Muted("\(selected.count) selected")
      Button(busy ? "Marking…" : "Mark as \(nextStatus?.label.lowercased() ?? "")") {
        if nextStatus == .mailed { confirmMailed = true } else { Task { await markSelected() } }
      }
      .buttonStyle(.primaryCompact).disabled(selected.isEmpty || busy).accessibilityIdentifier("markSelected")
    }
    .padding(.horizontal, 20).padding(.vertical, 10)
    .background(Theme.paperRaised)
    .overlay(alignment: .top) { Divider().overlay(Theme.rule) }
  }

  private func markSelected() async {
    guard let next = nextStatus, !selected.isEmpty, !busy else { return }
    busy = true
    defer { busy = false }
    do {
      // In the order of the list, so that a refusal names a letter where the person expects to find it.
      let ids = loader.items.map(\.id).filter(selected.contains)
      let moved = try await app.container.group.setStatusOfMany(messageIds: ids, status: next)
      app.show("\(Format.plural(moved, "letter")) marked as \(next.label.lowercased()).")
      selecting = false; selected = []
      await loader.refresh()
    } catch let e as AppError where e.isChangedMeanwhile {
      // Another volunteer got there first. Nothing moved in this request, and the list is out of date: look again.
      app.show("Someone else has just changed one of these letters. The list has been refreshed; nothing was marked.")
      await loader.refresh()
      selected.formIntersection(loader.items.map(\.id))
    } catch {
      // All or none: the ticks stay, so that the one letter named can be unticked and the rest tried again.
      app.show("Nothing was changed. " + (AppError.from(error).userMessage ?? "The letters could not be marked."))
    }
  }

  private var emptyText: String {
    switch filter ?? .status(.queued) {
    case .status(.queued): return "Nothing is waiting to be printed."
    case .held: return "No letter is held. A letter is held when the person it is for was moved or freed after it was written."
    case .status(.printed): return "Nothing is printed and waiting to be mailed."
    case .status(.returned): return "No letter has come back."
    default: return "No mailed letters to show."
    }
  }
}

private struct QueueRow: View {
  let item: QueueItem
  /// Selecting several: whether this row shows a tick box, and what is in it.
  enum Tick { case notSelecting, off, on, cannot }
  var tick = Tick.notSelecting
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
    let row = RecordRow(
      title: item.prisoner?.name ?? "Prisoner #\(letter.prisonerId ?? 0)",
      secondary: item.prisoner?.facility.map { $0.name + ($0.country.map { ", \($0)" } ?? "") },
      subtitle: facts.compactMap { $0 }.joined(separator: " · "),
      notice: letter.isHeld ? "Held: \(heldWord)" : letter.status == .returned ? "Came back: \((letter.returnReason ?? .unknown).choice.lowercased())" : letter.relayNote.map { "Note: \($0)" },
      horizontalPadding: tick == .notSelecting ? 20 : 8, action: action
    )
    if tick == .notSelecting {
      row
    } else {
      HStack(spacing: 0) {
        Image(systemName: tick == .on ? "checkmark.circle.fill" : tick == .cannot ? "circle.slash" : "circle")
          .font(.title3).foregroundStyle(tick == .on ? Theme.red : Theme.inkMuted).padding(.leading, 20)
          .accessibilityHidden(true)
        row
      }
      .opacity(tick == .cannot ? 0.5 : 1)
      .accessibilityAddTraits(tick == .on ? .isSelected : [])
      .accessibilityHint(tick == .cannot ? "Held letters are decided one at a time, on their own page." : "")
    }
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
        HStack(spacing: 20) {
          Button("Add a writer") { app.push(.addWriter) }.buttonStyle(.primaryCompact)
          Button("Print invite codes") { app.push(.inviteCodes) }.buttonStyle(.link)
        }
        .padding(20)
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
      Text(w.hasLiveToken ? "Claim token pending, good until \(w.tokenExpiresAt.map(Format.short) ?? "")" : "Unclaimed, no token")
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
        Text("Handing it over lets them read and print every letter the group mails, once letters are encrypted. Only the group-owner admin can, and only for people the group trusts with that.").font(Theme.bodyMedium)
        HStack(spacing: 20) {
          Button(busy ? "Sealing…" : "Hand it over") {
            Task { busy = true; await app.handKeyToWaitingMembers(); busy = false }
          }
          .buttonStyle(.primaryCompact).disabled(busy)
          Button("Group key") { app.push(.groupKey) }.buttonStyle(.link)
        }
      }
      .padding(16).frame(maxWidth: .infinity, alignment: .leading)
      .background(Theme.redWash, in: RoundedRectangle(cornerRadius: 8))
      .padding(.horizontal, 20).padding(.vertical, 8)
    }
  }
}
