import ABCCore
import Observation
import QuickLook
import SwiftUI

@MainActor @Observable
final class ThreadModel {
  private(set) var thread: Loadable<LetterThread> = .loading
  private(set) var retentionDays: Int?
  private(set) var busyMessageId: Int?
  /// A downloaded attachment ready to preview.
  var openFile: URL?

  @ObservationIgnored private let app: AppModel
  @ObservationIgnored private let chatId: Int
  init(app: AppModel, chatId: Int) { self.app = app; self.chatId = chatId }

  // Who is looking decides what the screen offers: a group member records replies and writes for its writers.
  var isStaff: Bool { app.user?.isStaff == true }
  var staffGroupId: Int? { app.user?.staffGroupId }

  func load() async {
    let fresh: Loadable<LetterThread> = await .from { try await app.container.letters.thread(chatId: chatId) }
    // A failed refresh keeps what is on screen; only a first load shows the error.
    if fresh.value != nil || thread.value == nil { thread = fresh }
    if retentionDays == nil { retentionDays = try? await app.container.letters.retentionDays() }
  }

  func retry() async {
    thread = .loading
    await load()
  }

  func delete(_ messageId: Int) async {
    busyMessageId = messageId
    do {
      try await app.container.letters.delete(messageId: messageId)
      app.show("Letter deleted.")
    } catch {
      app.show(AppError.from(error).userMessage ?? "Could not delete the letter.")
    }
    busyMessageId = nil
    await load()
  }

  func open(_ attachment: Attachment) async {
    do { openFile = try await app.container.letters.download(attachment) } catch {
      app.show(AppError.from(error).userMessage ?? "Could not download the file.")
    }
  }

  /// The letter being answered and the groups that mail to where the person is held now.
  private(set) var relayQuestion: (messageId: Int, facility: String, options: [SupportGroup])?
  var askingForRelay: Bool {
    get { relayQuestion != nil }
    set { if !newValue { relayQuestion = nil } }
  }

  /// A `choose_relay` hold: the person was moved to a facility where the writer has to say who mails the
  /// letter. Asks the directory where they are now, not what this screen loaded before the move.
  func askWhoMails(_ messageId: Int, prisonerId: Int) async {
    busyMessageId = messageId
    defer { busyMessageId = nil }
    do {
      let directory = app.container.directory
      let prisoner = try await directory.prisoner(id: prisonerId)
      guard let facilityId = prisoner.facilityId else { app.show("The directory does not say where they are held now."); return }
      let facility = try await directory.facility(id: facilityId)
      let options = facility.relayGroups.filter(\.isActive)
      if options.isEmpty {
        app.show("No group is listed yet that mails to \(facility.name). The letter waits until one is; you can also delete it.")
      } else {
        relayQuestion = (messageId, facility.name, options)
      }
    } catch {
      app.show(AppError.from(error).userMessage ?? "Could not look up who mails to them now.")
    }
  }

  func chooseRelay(_ group: SupportGroup) async {
    guard let messageId = relayQuestion?.messageId else { return }
    busyMessageId = messageId
    do {
      try await app.container.letters.chooseRelay(messageId: messageId, groupId: group.id)
      app.show("\(group.name) will print and mail it.")
    } catch {
      app.show(AppError.from(error).userMessage ?? "Could not set who mails the letter.")
    }
    busyMessageId = nil
    await load()
  }
}

/// After `thread.html`: the conversation as a timeline, newest at the bottom, with a Write button.
struct ThreadView: View {
  @State private var model: ThreadModel
  @State private var confirmDelete: Int?
  private let app: AppModel

  init(app: AppModel, chatId: Int) {
    self.app = app
    _model = State(initialValue: ThreadModel(app: app, chatId: chatId))
  }

  var body: some View {
    LoadableView(state: model.thread, retry: { Task { await model.retry() } }) { thread in
      timeline(thread).overlay(alignment: .bottomTrailing) { actions(thread).padding(20) }
    }
    .navigationTitle(model.thread.value?.title ?? "Conversation")
    .navigationBarTitleDisplayMode(.inline)
    // Also runs when coming back from compose, so a new or edited letter shows.
    .onAppear { Task { await model.load() } }
    .quickLookPreview($model.openFile)
    .confirmationDialog("Delete this letter?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }), titleVisibility: .visible) {
      Button("Delete", role: .destructive) { if let id = confirmDelete { Task { await model.delete(id) } } }
      Button("Keep it", role: .cancel) {}
    } message: {
      Text("It has not been printed yet, so it can still be withdrawn. This cannot be undone.")
    }
    .confirmationDialog("Who should mail it?", isPresented: $model.askingForRelay, titleVisibility: .visible) {
      ForEach(model.relayQuestion?.options ?? []) { g in Button(g.name) { Task { await model.chooseRelay(g) } } }
      Button("Not now", role: .cancel) {}
    } message: {
      Text("\(model.relayQuestion?.facility ?? "The new facility") only takes letters through a group. The one you choose prints this letter and mails it.")
    }
  }

  private func timeline(_ thread: LetterThread) -> some View {
    let mayChange = mayChangeLetters(viewerIsStaff: model.isStaff, viewerGroupId: model.staffGroupId, writer: thread.writer)
    return ScrollView {
      LazyVStack(alignment: .leading, spacing: 0) {
        header(thread)
        Divider().overlay(Theme.rule)
        if thread.letters.isEmpty { Muted("No letters in this conversation yet.", font: Theme.bodyLarge).padding(20) }
        ForEach(thread.letters) { letter in
          LetterCard(
            letter: letter, busy: model.busyMessageId == letter.id, mayChange: mayChange,
            onOpen: { a in Task { await model.open(a) } },
            onEdit: { app.push(.compose(ComposeRequest(prisonerId: thread.prisonerId, editMessageId: letter.id))) },
            onDelete: { confirmDelete = letter.id },
            onSendAgain: { app.push(.compose(sendAgain(letter, in: thread))) },
            onChooseRelay: { Task { await model.askWhoMails(letter.id, prisonerId: thread.prisonerId) } }
          )
          Divider().overlay(Theme.rule)
        }
        Color.clear.frame(height: 150) // room for the floating buttons under the last letter
      }
      .frame(maxWidth: 700, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
    .refreshable { await model.load() }
    .background(Theme.paper)
  }

  /// A returned letter is sent again as a new one that names it; a letter held as `reseal_needed` is replaced
  /// by a new one. A group writing for a managed writer keeps writing as them.
  private func sendAgain(_ letter: Letter, in thread: LetterThread) -> ComposeRequest {
    var request = ComposeRequest(prisonerId: thread.prisonerId)
    if model.isStaff, let writer = thread.writer, writer.anonymousForGroupId == nil { request.writerId = writer.id; request.writerName = writer.name }
    if letter.status == .returned { request.resendOf = letter.id } else { request.replaceHeldId = letter.id }
    return request
  }

  private func header(_ thread: LetterThread) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      if let p = thread.prisoner {
        Button(p.name + (p.facility.map { " · \($0.name)" } ?? "")) { app.push(.prisoner(p.id)) }.buttonStyle(.link)
      }
      if let w = thread.writer { Text("Writer: \(w.label)").font(Theme.bodyMedium) }
      let sent = thread.letters.filter { !$0.fromPrisoner }.count
      Muted("\(Format.plural(thread.letters.count, "letter")) · \(sent) sent · \(thread.letters.count - sent) received")
      if let days = model.retentionDays {
        Muted(days == 0 ? "Mailed letters are kept until you delete them." : "Mailed and returned letters, and replies, are removed after \(days) days unless you keep them; older ones may already be gone.", font: Theme.label)
      }
    }
    .padding(.horizontal, 20).padding(.vertical, 8)
  }

  @ViewBuilder private func actions(_ thread: LetterThread) -> some View {
    let writer = thread.writer
    VStack(alignment: .trailing, spacing: 10) {
      // A group records what came back from the prisoner, on any thread it can see.
      if model.isStaff, let writer {
        FloatingButton(title: "Record reply", symbol: "arrow.left", color: Theme.red) {
          app.push(.compose(ComposeRequest(prisonerId: thread.prisonerId, replyForUserId: writer.id)))
        }
      }
      // A writer writes in their own thread; a group only for writers it manages or as its anonymous writer.
      let groupMayWrite = model.isStaff && writer?.canBeWrittenFor(by: model.staffGroupId) == true
      if !model.isStaff || groupMayWrite {
        FloatingButton(title: "Write", symbol: "square.and.pencil") {
          if groupMayWrite, let writer, writer.anonymousForGroupId == nil {
            app.push(.compose(ComposeRequest(prisonerId: thread.prisonerId, writerId: writer.id, writerName: writer.name)))
          } else {
            app.push(.compose(ComposeRequest(prisonerId: thread.prisonerId)))
          }
        }
      }
    }
  }
}

struct LetterCard: View {
  let letter: Letter
  let busy: Bool
  let mayChange: Bool
  let onOpen: (Attachment) -> Void
  let onEdit: () -> Void
  let onDelete: () -> Void
  var onSendAgain: () -> Void = {}
  var onChooseRelay: () -> Void = {}

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Text(letter.fromPrisoner ? "← Received" : "→ Sent").font(Theme.titleMedium).foregroundStyle(letter.fromPrisoner ? Theme.red : Theme.ink)
        if let at = letter.createdAt { Muted(Format.long(at)) }
        Spacer()
        Tag(text: letter.status.label)
      }
      if letter.awaitingShare {
        // The letter exists and nobody has sealed it to this reader yet. Not an empty letter, and not a lost one.
        Muted("✉ Your group recorded this letter before your account had its encryption key, so it is not yours to open yet. It opens by itself the next time a member of the group signs in.")
      } else if letter.locked {
        Muted("🔒 This letter is encrypted and this device does not hold a key that opens it.")
      } else if !letter.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        Text(letter.body).font(Theme.bodyLarge).textSelection(.enabled)
      }
      if let note = letter.relayNote {
        VStack(alignment: .leading, spacing: 2) {
          FieldLabel("Note to relay group")
          Text(note).font(Theme.bodyMedium)
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.paperRaised, in: RoundedRectangle(cornerRadius: 4))
      }
      ForEach(letter.attachments) { a in AttachmentRow(attachment: a) { onOpen(a) } }
      if !statusLine.isEmpty { Muted(statusLine, font: Theme.label) }
      if letter.status == .returned { returned }
      if let reason = letter.heldReason, letter.isHeld { held(reason) }
      if letter.canEdit, !letter.locked, !letter.awaitingShare, mayChange {
        HStack(spacing: 20) {
          Button("Edit", action: onEdit).buttonStyle(.quietLink)
          Button("Delete", action: onDelete).buttonStyle(.destructiveLink)
        }
        .disabled(busy)
      }
    }
    .padding(.horizontal, 20).padding(.vertical, 14)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// Why it came back, in the app's words; what the group wrote, in theirs; and what can be done about it.
  @ViewBuilder private var returned: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("It came back: \(letter.returnReason?.sentence ?? ReturnReason.unknown.sentence)").font(Theme.bodyMedium).foregroundStyle(Theme.red)
      if let note = letter.returnNote {
        FieldLabel("From \(letter.relayGroupName ?? "the relay group"), about the envelope")
        Text(note).font(Theme.bodyMedium).textSelection(.enabled)
      }
      if let again = letter.resentAs.last {
        Muted("Sent again\(again.createdAt.map { " on \(Format.long($0))" } ?? ""). That letter is \(again.status.label.lowercased()).")
      } else if mayChange, !letter.fromPrisoner {
        if letter.returnReason?.doubtsTheAddress == true { Muted("They may not be where the directory says. Check their page before sending it again.") }
        if !letter.locked, !letter.awaitingShare { Button("Send it again", action: onSendAgain).buttonStyle(.link).disabled(busy) }
      }
    }
    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
    .background(Theme.redWash, in: RoundedRectangle(cornerRadius: 4))
  }

  /// A queued letter that is waiting because the person was moved or freed after it was written (API PR #106).
  @ViewBuilder private func held(_ reason: HeldReason) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      switch reason {
      case .chooseRelay:
        Text("They were moved. This letter is waiting for \(mayChange ? "you" : "the writer") to choose who mails it now.").font(Theme.bodyMedium).foregroundStyle(Theme.red)
        if mayChange { Button("Choose who mails it", action: onChooseRelay).buttonStyle(.link).disabled(busy) }
      case .resealNeeded:
        Text("They were moved, and this letter is sealed to a group that does not mail to the new facility. Nobody else can open it to pass it on, so it has to be sent again from \(mayChange ? "this phone" : "the writer's device").").font(Theme.bodyMedium).foregroundStyle(Theme.red)
        if mayChange, !letter.locked, !letter.awaitingShare { Button("Send it again", action: onSendAgain).buttonStyle(.link).disabled(busy) }
      case .prisonerFree:
        Text("They have been released, so this letter is waiting: mailed to a prison they have left, it may never reach them. The group prints it only on purpose.\(mayChange ? " You can delete it, or leave it if you know it will be forwarded." : "")").font(Theme.bodyMedium).foregroundStyle(Theme.red)
      case .other:
        Text("This letter is being held and will not be printed for now.").font(Theme.bodyMedium).foregroundStyle(Theme.red)
      }
    }
    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
    .background(Theme.redWash, in: RoundedRectangle(cornerRadius: 4))
  }

  private var statusLine: String {
    let group = letter.relayGroupName ?? "the relay group"
    let on = letter.statusChangedAt.map { " on \(Format.long($0))" } ?? ""
    switch letter.status {
    case .queued:
      if letter.isHeld { return "" } // the hold says it, below
      if let name = letter.relayGroupName { return "Waiting for \(name) to print it" }
      return letter.relayGroupId != nil ? "Waiting for the relay group to print it" : "Queued. No relay group is assigned to this facility yet."
    case .printed: return "Printed by \(group)\(on)"
    case .mailed: return "Mailed by \(group)\(on)"
    case .received: return "Recorded by a support group"
    case .returned: return "Came back\(on)"
    case .unknown: return ""
    }
  }
}

struct AttachmentRow: View {
  let attachment: Attachment
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 8) {
        Text("📎")
        Text(attachment.name).font(Theme.bodyMedium).foregroundStyle(Theme.red).multilineTextAlignment(.leading)
        Spacer()
        Muted(attachment.sizeLabel, font: Theme.label)
      }
      .padding(.vertical, 6).contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Open \(attachment.name), \(attachment.sizeLabel)")
  }
}
