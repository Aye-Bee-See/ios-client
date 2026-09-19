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

  /// The lifecycle only moves forward; the API refuses anything else and its sentence is shown.
  func advance() async {
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
      var updated = try await app.container.group.setStatus(messageId: messageId, status: next)
      updated.attachments = current.letter.attachments // the status answer does not repeat them
      current.letter = updated
      item = .loaded(current)
      app.show("Marked as \(next.label.lowercased()).")
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
        Button("It is in the post") { Task { await model.advance() } }
        Button("Not yet", role: .cancel) {}
      } message: {
        Text("Do this once the letter is actually in the post. The writer will see it as mailed, and it cannot be moved back.")
      }
      .confirmationDialog("Share with a partner group", isPresented: $choosePartner, titleVisibility: .visible) {
        ForEach(model.partners) { g in Button(g.name) { Task { await model.share(with: g) } } }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text("They will be able to read and print this letter. It stays in your queue: your group still marks it printed and mailed, so agree between you who posts it.")
      }
  }

  private func content(_ item: QueueItem) -> some View {
    let letter = item.letter, p = item.prisoner
    return Screen {
      HStack(spacing: 8) {
        Tag(text: letter.status.label)
        if let at = letter.createdAt { Muted("Written \(Format.long(at))") }
      }
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
      case .queued: Button("Mark as printed") { Task { await model.advance() } }.buttonStyle(.primary).accessibilityIdentifier("advance")
      case .printed: Button("Mark as mailed") { confirmMailed = true }.buttonStyle(.primary).accessibilityIdentifier("advance")
      case .mailed: Muted("Mailed\(letter.statusChangedAt.map { " on \(Format.long($0))" } ?? ""). Nothing more to do.", font: Theme.bodyLarge)
      default: EmptyView()
      }
      // End-to-end only, and only where the facility has another relay group: the server permits no other readers.
      if !model.partners.isEmpty, !letter.locked, letter.status != .mailed {
        Button("Share with a partner group") { choosePartner = true }.buttonStyle(.outlineWide)
      }
      if let threadId = letter.threadId { Button("Open the conversation") { app.push(.thread(chatId: threadId)) }.buttonStyle(.link) }
    }
    .disabled(model.busy)
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
