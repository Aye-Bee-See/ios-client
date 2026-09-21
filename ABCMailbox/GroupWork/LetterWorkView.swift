import ABCCore
import Observation
import QuickLook
import SwiftUI
import UIKit

/// One letter as the relay group sees it: who it goes to, what it says, and where it is in the queue.
@MainActor @Observable
final class LetterWorkModel {
  private(set) var item: Loadable<QueueItem> = .loading
  private(set) var busy = false
  /// End-to-end only: other relay groups of the facility this letter could be shared with.
  private(set) var partners: [SupportGroup] = []
  var openFile: URL?

  @ObservationIgnored private let app: AppModel
  @ObservationIgnored private let messageId: Int
  init(app: AppModel, messageId: Int) { self.app = app; self.messageId = messageId }

  func load() async {
    item = .loading
    item = await .from { try await app.container.group.queueItem(messageId: messageId) }
    if let prisonerId = item.value?.letter.prisonerId { partners = await app.container.group.partners(forPrisoner: prisonerId) }
  }

  /// Seals this letter's content key to a partner relay group. The letter itself is not re-encrypted or moved.
  func share(with partner: SupportGroup) async {
    busy = true
    defer { busy = false }
    do {
      try await app.container.group.share(messageId: messageId, withGroup: partner.id)
      app.show("\(partner.name) can now read this letter.")
    } catch {
      app.show(AppError.from(error).userMessage ?? "Could not share the letter.")
    }
  }

  /// The post brought it back (API PR #105). The writer is told why, and can send it again.
  func markReturned(reason: ReturnReason, note: String) async -> Bool {
    guard var current = item.value else { return false }
    busy = true
    defer { busy = false }
    do {
      var updated = try await app.container.group.markReturned(messageId: messageId, reason: reason, note: note)
      updated.attachments = current.letter.attachments
      current.letter = updated
      item = .loaded(current)
      // Three of the reasons say the directory may be wrong about where this person is, and a group is who can fix that.
      app.show("Recorded as returned. The writer has been told." + (reason.doubtsTheAddress ? " If your group knows where they are now, the directory needs correcting." : ""))
      return true
    } catch {
      let e = AppError.from(error)
      if e.isChangedMeanwhile {
        await load()
        app.show("Someone else changed this letter a moment ago. This is how it stands now.")
        return true // the sheet's question has been answered by somebody else; close it and show the letter
      }
      app.show(e.userMessage ?? "Could not record the return.")
      return false
    }
  }

  /// The lifecycle only moves forward; the API refuses anything else and its sentence is shown.
  ///
  /// `release`: the letter is held and is being printed all the same, which the screen has just asked about.
  func advance(release: Bool = false) async {
    guard var current = item.value else { return }
    let next: LetterStatus
    switch current.letter.status {
    case .queued: next = .printed
    case .printed: next = .mailed
    default: return
    }
    busy = true
    defer { busy = false }
    do {
      var updated = try await app.container.group.setStatus(messageId: messageId, status: next, release: release)
      updated.attachments = current.letter.attachments // the status answer does not repeat them
      current.letter = updated
      item = .loaded(current)
      app.show("Marked as \(next.label.lowercased()).")
    } catch let e as AppError where e.isChangedMeanwhile {
      // Another volunteer, or a second tap, got there first. The letter is very probably where it was wanted: show it.
      await load()
      app.show("Someone else changed this letter a moment ago. This is how it stands now.")
    } catch let e as AppError where e.isLetterHeld {
      // Held since this screen loaded: the person was moved or freed in the meantime. Show it, and let them decide.
      await load()
      app.show("This letter has been held since you opened it. Read why before printing it.")
    } catch {
      app.show(AppError.from(error).userMessage ?? "Could not update the letter.")
    }
  }

  func open(_ attachment: Attachment) async {
    do { openFile = try await app.container.letters.download(attachment) } catch {
      app.show(AppError.from(error).userMessage ?? "Could not download the file.")
    }
  }
}

/// One queued letter as the volunteer at the printer needs it: address, rules, text, and the two status buttons.
struct LetterWorkView: View {
  @State private var model: LetterWorkModel
  @State private var confirmMailed = false
  @State private var confirmRelease = false
  @State private var recordReturn = false
  @State private var choosePartner = false
  private let app: AppModel

  init(app: AppModel, messageId: Int) {
    self.app = app
    _model = State(initialValue: LetterWorkModel(app: app, messageId: messageId))
  }

  var body: some View {
    LoadableView(state: model.item, retry: { Task { await model.load() } }) { item in content(item) }
      .navigationTitle("Letter to print")
      .navigationBarTitleDisplayMode(.inline)
      .task { if model.item.value == nil { await model.load() } }
      .quickLookPreview($model.openFile)
      .confirmationDialog("Mark as mailed?", isPresented: $confirmMailed, titleVisibility: .visible) {
        Button("It is in the mail") { Task { await model.advance() } }
        Button("Not yet", role: .cancel) {}
      } message: {
        Text("Do this once the letter is actually in the mail. The writer will see it as mailed, and it cannot be moved back.")
      }
      .confirmationDialog("Print it anyway?", isPresented: $confirmRelease, titleVisibility: .visible) {
        Button("Print it anyway") { Task { await model.advance(release: true) } }
        Button("Leave it waiting", role: .cancel) {}
      } message: {
        Text("This lifts the hold. Do it only if your group knows the letter will reach them where it is going.")
      }
      .sheet(isPresented: $recordReturn) {
        ReturnSheet(groupName: app.user?.displayName) { reason, note in await model.markReturned(reason: reason, note: note) }
      }
      .confirmationDialog("Share with a partner group", isPresented: $choosePartner, titleVisibility: .visible) {
        ForEach(model.partners) { g in Button(g.name) { Task { await model.share(with: g) } } }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text("They will be able to read and print this letter. It stays in your queue: your group still marks it printed and mailed, so agree between you who mails it.")
      }
  }

  private func content(_ item: QueueItem) -> some View {
    let letter = item.letter, p = item.prisoner
    return Screen {
      HStack(spacing: 8) {
        Tag(text: letter.statusLabel)
        if let at = letter.createdAt { Muted("Written \(Format.long(at))") }
      }
      if let reason = letter.heldReason, letter.isHeld { AlertBanner(Self.heldText(reason)) }
      envelope(letter, p)
      if let note = letter.relayNote { AlertBanner("Note from the writer: \(note)") }
      if let f = p?.facility {
        SectionTitle("Mail rules · \(f.name)")
        MailRulesList(rules: f.rules, emptyText: "No rules recorded. Check before mailing.")
      }

      SectionTitle("The letter")
      if letter.locked {
        Muted("🔒 This letter is encrypted and this device does not hold a key that opens it.", font: Theme.bodyLarge)
      } else {
        Text(letter.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "(No text. See the attached file.)" : letter.body).font(Theme.bodyLarge).textSelection(.enabled)
      }
      ForEach(letter.attachments) { a in AttachmentRow(attachment: a) { Task { await model.open(a) } } }

      if !letter.locked, !letter.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        Button("Print the letter") { PrintLetter.print(jobName: "Letter to \(p?.name ?? "prisoner")", body: letter.body) }.buttonStyle(.outlineWide)
      }
      switch letter.status {
      case .queued:
        if letter.isHeld {
          // Printing a held letter is a decision, never an oversight: the API wants it said, and so does this screen.
          Button("Print it anyway…") { confirmRelease = true }.buttonStyle(.outlineWide).accessibilityIdentifier("release")
        } else {
          Button("Mark as printed") { Task { await model.advance() } }.buttonStyle(.primary).accessibilityIdentifier("advance")
        }
      case .printed: Button("Mark as mailed") { confirmMailed = true }.buttonStyle(.primary).accessibilityIdentifier("advance")
      case .mailed:
        Muted("Mailed\(letter.statusChangedAt.map { " on \(Format.long($0))" } ?? "").", font: Theme.bodyLarge)
        Button("It came back…") { recordReturn = true }.buttonStyle(.outlineWide).accessibilityIdentifier("returned")
      case .returned:
        Muted("Came back\(letter.statusChangedAt.map { " on \(Format.long($0))" } ?? ""): \((letter.returnReason ?? .unknown).choice.lowercased()). The writer has been told and can send it again.", font: Theme.bodyLarge)
        if let note = letter.returnNote { Muted("Your group's note: \(note)") }
      default: EmptyView()
      }
      // End-to-end only, and only where the facility has another relay group: the server permits no other readers.
      if !model.partners.isEmpty, !letter.locked, letter.status != .mailed, letter.status != .returned {
        Button("Share with a partner group") { choosePartner = true }.buttonStyle(.outlineWide)
      }
      if let threadId = letter.threadId { Button("Open the conversation") { app.push(.thread(chatId: threadId)) }.buttonStyle(.link) }
    }
    .disabled(model.busy)
  }

  /// What a hold means for the person at the printer.
  static func heldText(_ reason: HeldReason) -> String {
    switch reason {
    case .prisonerFree: return "Held: they have been released since this was written. Mailed to a prison they have left, it may never reach them. Print it only if your group knows it will."
    case .chooseRelay: return "Held: they were moved, and the writer has not yet chosen who mails this letter."
    case .resealNeeded: return "Held: they were moved to a facility your group does not mail to. The writer has been asked to send it again, to the group that does."
    case .other: return "Held: something changed for this person after the letter was written. Check their page before printing it."
    }
  }

  /// The envelope: name, number, facility, address. Selectable so it can be copied to a label app.
  /// The legal name and inmate number come first, because that is what the mailroom checks.
  private func envelope(_ letter: Letter, _ p: Prisoner?) -> some View {
    var lines = [(p?.birthName ?? p?.name ?? "Prisoner #\(letter.prisonerId ?? 0)") + (p?.inmateId.map { " #\($0)" } ?? "")]
    if let f = p?.facility { lines += [f.name] + f.addressLines + [f.country].compactMap { $0 } }
    return VStack(alignment: .leading, spacing: 4) {
      FieldLabel("Address the envelope to")
      Text(lines.joined(separator: "\n")).font(Theme.bodyLarge).textSelection(.enabled)
      if let p, p.birthName != nil {
        Muted("Goes by \(p.name). Facilities usually need the legal name on the envelope.", font: Theme.label).padding(.top, 4)
      }
    }
    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
    .background(Theme.paperRaised, in: RoundedRectangle(cornerRadius: 4))
  }
}

/// Recording that the post brought a letter back: what happened, and optionally what the envelope said.
private struct ReturnSheet: View {
  let groupName: String?
  let save: (ReturnReason, String) async -> Bool
  @Environment(\.dismiss) private var dismiss
  @State private var reason: ReturnReason?
  @State private var note = ""
  @State private var saving = false

  private var tooLong: Bool { note.trimmingCharacters(in: .whitespacesAndNewlines).count > GroupRepository.returnNoteLimit }

  var body: some View {
    NavigationStack {
      Screen {
        Muted("The writer is told that the letter came back, and why. It cannot be undone.", font: Theme.bodyLarge)
        SectionTitle("What happened")
        ForEach(ReturnReason.allCases) { r in
          Button { reason = r } label: {
            HStack(spacing: 10) {
              Image(systemName: reason == r ? "largecircle.fill.circle" : "circle").foregroundStyle(reason == r ? Theme.red : Theme.inkMuted)
              Text(r.choice).font(Theme.bodyLarge).foregroundStyle(Theme.ink)
              Spacer()
            }
            .padding(.vertical, 6).contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityAddTraits(reason == r ? .isSelected : [])
        }
        SectionTitle("What the envelope said (optional)")
        TextField("For example: Stamped NOT HERE", text: $note, axis: .vertical).lineLimit(2...4).font(Theme.bodyLarge)
          .padding(10).background(Theme.paperRaised, in: RoundedRectangle(cornerRadius: 4))
        Text("\(note.trimmingCharacters(in: .whitespacesAndNewlines).count) of \(GroupRepository.returnNoteLimit)").font(Theme.label).foregroundStyle(tooLong ? Theme.red : Theme.inkMuted)
        AlertBanner("The writer reads this note, and it is not encrypted, even when letters are. Write what the envelope said, and nothing about what the letter said.")
        Button(saving ? "Saving…" : "Record the return") {
          guard let reason else { return }
          Task { saving = true; if await save(reason, note) { dismiss() }; saving = false }
        }
        .buttonStyle(.primary).disabled(reason == nil || tooLong || saving).accessibilityIdentifier("recordReturn")
      }
      .navigationTitle("It came back")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
    }
  }
}

/// Prints a letter with the system print panel (AirPrint printers, and "Save to Files" as a PDF
/// from the share button in the preview), so the app needs no printer code. Only the letter
/// itself is printed, since that page is what goes in the envelope; the address and the note to
/// the relay group stay on the screen.
enum PrintLetter {
  @MainActor
  static func print(jobName: String, body: String) {
    let html = """
      <html><head><meta charset="utf-8"><style>
        body { font-family: Georgia, 'Times New Roman', serif; font-size: 12pt; line-height: 1.5; color: #000; }
        p { white-space: pre-wrap; margin: 0; }
      </style></head><body><p>\(escape(body))</p></body></html>
      """
    let formatter = UIMarkupTextPrintFormatter(markupText: html)
    formatter.perPageContentInsets = UIEdgeInsets(top: 62, left: 62, bottom: 62, right: 62) // 2.2 cm, in points
    let info = UIPrintInfo(dictionary: nil)
    info.jobName = jobName
    info.outputType = .grayscale
    let controller = UIPrintInteractionController.shared
    controller.printInfo = info
    controller.printFormatter = formatter
    // An iPad shows the panel as a popover, which needs somewhere to point; an iPhone shows a sheet.
    let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
    if UIDevice.current.userInterfaceIdiom == .pad, let view = window?.rootViewController?.view {
      controller.present(from: CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1), in: view, animated: true)
    } else {
      controller.present(animated: true)
    }
  }

  static func escape(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
  }
}
