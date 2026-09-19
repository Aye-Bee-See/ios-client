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
            onDelete: { confirmDelete = letter.id }
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

  private func header(_ thread: LetterThread) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      if let p = thread.prisoner {
        Button(p.name + (p.facility.map { " · \($0.name)" } ?? "")) { app.push(.prisoner(p.id)) }.buttonStyle(.link)
      }
      if let w = thread.writer { Text("Writer: \(w.label)").font(Theme.bodyMedium) }
      let sent = thread.letters.filter { !$0.fromPrisoner }.count
      Muted("\(Format.plural(thread.letters.count, "letter")) · \(sent) sent · \(thread.letters.count - sent) received")
      if let days = model.retentionDays {
        Muted(days == 0 ? "Mailed letters are kept until you delete them." : "Mailed letters and replies are removed after \(days) days unless you keep them; older ones may already be gone.", font: Theme.label)
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

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Text(letter.fromPrisoner ? "← Received" : "→ Sent").font(Theme.titleMedium).foregroundStyle(letter.fromPrisoner ? Theme.red : Theme.ink)
        if let at = letter.createdAt { Muted(Format.long(at)) }
        Spacer()
        Tag(text: letter.status.label)
      }
      if letter.locked {
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
      if letter.canEdit, !letter.locked, mayChange {
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

  private var statusLine: String {
    let group = letter.relayGroupName ?? "the relay group"
    let on = letter.statusChangedAt.map { " on \(Format.long($0))" } ?? ""
    switch letter.status {
    case .queued:
      if let name = letter.relayGroupName { return "Waiting for \(name) to print it" }
      return letter.relayGroupId != nil ? "Waiting for the relay group to print it" : "Queued. No relay group is assigned to this facility yet."
    case .printed: return "Printed by \(group)\(on)"
    case .mailed: return "Mailed by \(group)\(on)"
    case .received: return "Recorded by a support group"
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
