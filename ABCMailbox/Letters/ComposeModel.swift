import ABCCore
import Observation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The API's default since PR #84 (`UPLOAD_MAX_BYTES`, 20 MiB).
let maxAttachmentBytes = 20 * 1024 * 1024
let attachmentMimeTypes = ["application/pdf", "image/jpeg", "image/png", "image/webp"]

/// New letter, edit of a queued one, or (for a group) a prisoner's reply being
/// recorded. Loads the prisoner and facility (for the rules card and relay
/// resolution), restores a draft, autosaves the draft while typing, and on send
/// creates the letter then uploads attachments.
@MainActor @Observable
final class ComposeModel {
  var body = "" { didSet { if body != oldValue { edited() } } }
  var note = "" { didSet { if note != oldValue { edited() } } }
  var selectedRelay: Int? { didSet { if selectedRelay != oldValue { edited() } } }
  var showNote = false
  /// The letter was written by hand and handed to the relay group to mail (API PR #118). Nothing is printed; a
  /// transcription is optional; a photo of the page may be attached now or later, until the group mails it.
  var onPaper = false { didSet { if onPaper != oldValue { edited() } } }
  private(set) var prisoner: Prisoner?
  private(set) var facility: Facility?
  private(set) var relay: RelayChoice = .direct
  private(set) var attachments: [StagedFile] = []
  private(set) var loading = true
  private(set) var sending = false
  private(set) var progress: String?
  var error: String?

  let request: ComposeRequest
  @ObservationIgnored private let app: AppModel
  @ObservationIgnored private var autosave: Task<Void, Never>?
  @ObservationIgnored private var sent = false
  /// One key per letter, repeated if this screen tries twice and carried into the outbox if it gives up
  /// (API PR #97). A changed letter is a different letter, so editing the text makes a new key.
  @ObservationIgnored private var sendKey: (key: String, body: String)?

  init(app: AppModel, request: ComposeRequest) {
    self.app = app
    self.request = request
  }

  // Read when needed, not captured when the screen is built: someone who taps "Write a letter" while
  // signed out signs in with this screen already open underneath.
  private var userId: Int? { app.user?.id }
  private var isStaff: Bool { app.user?.isStaff == true }
  private var staffGroupId: Int? { app.user?.staffGroupId }

  var editing: Bool { request.editMessageId != nil }
  /// Group accounts: recording a prisoner's reply rather than writing a letter.
  var recordingReply: Bool { request.replyForUserId != nil }
  /// Group accounts: who the letter is from ("Anonymous writer" or a managed writer's name).
  var writingAs: String? {
    if recordingReply { return nil }
    if let name = request.writerName { return name }
    return isStaff && !editing ? "Anonymous writer" : nil
  }
  // Drafts belong to a writer's own letters; a group's letters for others are not drafted on this phone.
  /// The letter this one starts from: one that came back, or one held because it must be sealed again.
  private var copiedFromId: Int? { request.resendOf ?? request.replaceHeldId }
  private var usesDrafts: Bool { !editing && request.writerId == nil && !recordingReply && request.outboxId == nil && copiedFromId == nil && !isStaff }
  /// Said above the editor, so that nobody wonders why a new letter is already written.
  var startedFrom: String? {
    if request.resendOf != nil { return "This is the letter that came back. Check where they are now and what the mail room objected to, change what you need to, and send it again." }
    if request.replaceHeldId != nil { return "This is the letter that was waiting. Sending it seals it to the group that mails to the new facility, and removes the waiting copy." }
    return nil
  }

  var title: String { recordingReply ? "Record a reply" : editing ? "Edit letter" : "New letter" }
  var sendLabel: String { progress ?? (recordingReply ? "Save reply" : editing ? "Save changes" : onPaper ? "Log the paper letter" : "Send letter") }
  /// A paper letter can be chosen for a new outgoing letter only: never for a reply, and never on an edit (the API ignores it).
  var canBeOnPaper: Bool { !recordingReply && !editing && request.outboxId == nil }
  var characters: Int { body.count }
  var pages: Int { estimatePages(characters: characters) }
  private var mailRules: MailRules { facility?.rules ?? MailRules() }
  /// What the facility's rules mean for this letter; recomputed as the writer types.
  var advice: [ComposeAdvice] { composeAdvice(rules: mailRules, estimatedPages: pages, imageAttachments: attachments.filter(\.isImage).count) }
  /// Where pictures are refused only a PDF may be attached (API guidance for `no_photos`).
  var imagesAllowed: Bool { recordingReply || !mailRules.forbidsPhotos }
  var allowedTypes: [UTType] { imagesAllowed ? [.pdf, .jpeg, .png, .webP] : [.pdf] }

  private var relayIsBlocked: Bool { if case .blocked = relay { return true } else { return false } }
  private var needsRelayChoice: Bool {
    if case .choose(_, required: true) = relay { return !recordingReply && selectedRelay == nil }
    return false
  }
  // A recorded reply is not mailed anywhere, so the facility's routing cannot block it.
  var canSend: Bool {
    !loading && !sending && (recordingReply || (!relayIsBlocked && !needsRelayChoice))
      // A paper letter needs no text and no file: the record is the point.
      && (onPaper || !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
  }

  func load() async {
    guard loading else { return }
    let directory = app.container.directory
    let found = try? await directory.prisoner(id: request.prisonerId)
    var place = found?.facility
    if let facilityId = found?.facilityId, let full = try? await directory.facility(id: facilityId) { place = full }
    let resolved = resolveRelay(place)
    var body = "", note = ""
    var selected: Int? = { if case .automatic(let g) = resolved { return g.id } else { return nil } }()
    var restored = false, copyFailed = false
    var missingFiles: [String] = []
    if let editId = request.editMessageId {
      if let letter = try? await app.container.letters.letter(messageId: editId) {
        body = letter.body; note = letter.relayNote ?? ""; selected = letter.relayGroupId ?? selected
      }
    } else if let copyId = copiedFromId {
      // The server has no "send again": in end-to-end mode it could not read the letter to copy it. The words
      // and the files are read here and travel again. The relay group is not copied: the facility may have changed.
      if let letter = try? await app.container.letters.letter(messageId: copyId), !letter.locked {
        body = letter.body; note = letter.relayNote ?? ""
        for attachment in letter.attachments {
          guard let url = try? await app.container.letters.download(attachment), let bytes = try? Data(contentsOf: url),
            let staged = try? app.container.files.stage(data: bytes, name: attachment.name, mimeType: attachment.mimeType)
          else { missingFiles.append(attachment.name); continue }
          attachments.append(staged)
        }
      } else {
        copyFailed = true
      }
    } else if let outboxId = request.outboxId, let queued = app.container.outbox.open(outboxId) {
      body = queued.payload.body; note = queued.payload.relayNote ?? ""; selected = queued.payload.relayChapter ?? selected
      attachments = queued.files
      // Unchanged, it is still the same letter: an earlier attempt may have arrived unheard, and only the
      // same key lets the server say so. Edited, it is a different letter and gets a new key.
      sendKey = (queued.payload.idempotencyKey, body)
    } else if usesDrafts, let userId, let draft = app.container.drafts.load(userId: userId, prisonerId: request.prisonerId) {
      body = draft.body; note = draft.note ?? ""; selected = draft.relayChapter ?? selected; restored = true
    }
    prisoner = found; facility = place; relay = resolved
    self.body = body; self.note = note; selectedRelay = selected
    showNote = !note.isEmpty
    error = found == nil ? "Could not load this prisoner." : copyFailed ? "Could not read the earlier letter. You can write it again here." : missingFiles.isEmpty ? nil : "These files could not be copied from the earlier letter: \(missingFiles.joined(separator: ", ")). Attach them again if you still have them."
    loading = false
    autosave?.cancel() // loading the text is not an edit
    if restored { app.show("Draft restored.") }
  }

  /// Autosave: whenever the text changes, wait for a pause, then persist.
  private func edited() {
    error = nil
    guard usesDrafts, !loading, !sent, let userId else { return }
    autosave?.cancel()
    autosave = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(600))
      guard !Task.isCancelled, let self else { return }
      self.saveDraft(userId: userId)
    }
  }

  private func saveDraft(userId: Int) {
    guard !sent else { return }
    let drafts = app.container.drafts
    if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      drafts.delete(userId: userId, prisonerId: request.prisonerId)
    } else {
      drafts.save(userId: userId, prisonerId: request.prisonerId, draft: Draft(body: body, note: note.isEmpty ? nil : note, relayChapter: selectedRelay))
    }
  }

  /// Leaving the screen (or the app going to the background) must not lose the last few keystrokes.
  func flushDraft() {
    autosave?.cancel()
    if usesDrafts, !loading, let userId { saveDraft(userId: userId) }
  }

  // MARK: Attachments

  func attach(documentAt url: URL) {
    guard let staged = try? app.container.files.stage(documentAt: url) else { error = "Could not read that file."; return }
    accept(staged)
  }

  /// A photo from the library or the camera. Phones produce HEIC; the API takes JPEG, so everything is re-encoded.
  func attach(image: UIImage, name: String) {
    guard let data = image.jpegData(compressionQuality: 0.85), let staged = try? app.container.files.stage(data: data, name: name, mimeType: "image/jpeg") else {
      error = "Could not read that photo."
      return
    }
    accept(staged, tooBig: "That photo is over 20 MB. Try a lower camera resolution.")
  }

  private func accept(_ staged: StagedFile, tooBig: String = "That file is over 20 MB.") {
    let files = app.container.files
    if staged.isImage, !imagesAllowed {
      files.discard(staged); error = "This facility refuses pictures, so an image cannot be attached. A PDF can."
    } else if !attachmentMimeTypes.contains(staged.mimeType) {
      files.discard(staged); error = "Only PDF, JPEG, PNG, or WebP files can be attached."
    } else if staged.size > maxAttachmentBytes {
      files.discard(staged); error = tooBig
    } else {
      attachments.append(staged); error = nil
    }
  }

  func remove(_ staged: StagedFile) {
    app.container.files.discard(staged)
    attachments.removeAll { $0 == staged }
  }

  // MARK: Sending

  func send() async {
    guard canSend else { return }
    let relayChapter: Int? = switch relay {
    case .choose: selectedRelay
    case .automatic(let group): group.id
    default: nil
    }
    sending = true; error = nil; progress = editing ? "Saving…" : "Sending…"
    let letters = app.container.letters
    let relayNote = note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : note
    do {
      if let editId = request.editMessageId {
        try await letters.edit(LetterEdit(messageId: editId, body: body, relayNote: relayNote, relayChapter: relayChapter))
        await uploadThen(messageId: editId, chatId: nil)
      } else {
        let letter = NewLetter(
          prisonerId: request.prisonerId, body: body, relayNote: relayNote, relayChapter: relayChapter,
          asWriterId: request.replyForUserId ?? request.writerId, fromPrisoner: recordingReply,
          // End-to-end: the server lets a group hold an envelope where it relays for the facility (or manages the writer).
          groupRelaysFacility: staffGroupId.map { id in facility?.relayGroups.contains { $0.id == id } == true } ?? false,
          idempotencyKey: keyForThisLetter(), resendOf: request.resendOf, paper: onPaper && canBeOnPaper
        )
        do {
          let created = try await letters.send(letter)
          finished()
          await removeHeldCopy()
          await uploadThen(messageId: created.id, chatId: created.threadId)
        } catch let e as AppError where e.meansNotReachingOurServer && request.replaceHeldId == nil {
          // No answer is not a reason to lose the evening's letter: it goes to the outbox and is sent when the
          // phone is next online. "No answer" includes a timeout, where the letter may in fact have arrived:
          // the outbox retries under the same Idempotency-Key, so the server returns that letter rather than
          // making a second. If the server answered "no", the writer sees that now, while they can still fix it.
          try app.container.outbox.queue(prisonerName: prisoner?.name ?? "Prisoner #\(request.prisonerId)", writingAs: request.writerId != nil ? writingAs : nil, letter: letter, attachments: attachments)
          attachments = []
          finished()
          sending = false; progress = nil
          await app.notifier.askPermissionOnce()
          app.pop()
          app.show("No connection. Your letter is saved on this phone and will be sent when you are back online.")
        }
      }
    } catch {
      sending = false; progress = nil
      self.error = AppError.from(error).userMessage ?? (editing ? "Could not save the letter." : "Could not send the letter.")
    }
  }

  /// The new letter exists, sealed for the new facility: the held one it replaces goes. In this order, so
  /// that a failure in between leaves two letters (one visibly held, and deletable) rather than none.
  private func removeHeldCopy() async {
    guard let held = request.replaceHeldId else { return }
    do { try await app.container.letters.delete(messageId: held) } catch {
      app.show("The letter was sent, but the waiting copy could not be removed. Delete it in the conversation.")
    }
  }

  /// The letter has left this screen, to the server or to the outbox: the draft and any outbox copy it came from are done with.
  private func finished() {
    sent = true
    autosave?.cancel()
    if usesDrafts, let userId { app.container.drafts.delete(userId: userId, prisonerId: request.prisonerId) }
    if let old = request.outboxId { app.container.outbox.delete(old) }
  }

  private func keyForThisLetter() -> String {
    // The key covers the letter as it is: on paper or typed is part of that (the API's fingerprint includes `paper`).
    let body = (onPaper ? "paper:" : "") + body
    if let sendKey, sendKey.body == body { return sendKey.key }
    let fresh = UUID().uuidString
    sendKey = (fresh, body)
    return fresh
  }

  /// The letter exists; attach files one by one. A failed upload is reported but the letter stays sent.
  private func uploadThen(messageId: Int, chatId: Int?) async {
    let letters = app.container.letters
    var failed: [String] = []
    for (i, file) in attachments.enumerated() {
      progress = "Uploading \(file.name) (\(i + 1) of \(attachments.count))…"
      do {
        _ = try await letters.upload(messageId: messageId, staged: file)
        app.container.files.discard(file)
      } catch {
        failed.append(file.name)
      }
    }
    var thread = chatId
    if thread == nil { thread = (try? await letters.letter(messageId: messageId))?.threadId }
    sending = false; progress = nil
    if !failed.isEmpty { app.show("The letter was sent, but these files did not upload: \(failed.joined(separator: ", ")).") }
    if let thread { app.letterSent(chatId: thread) } else { app.pop() }
  }
}
