import Foundation
import Network
import Observation

/// A file waiting with a queued letter. `key` is repeated on every retry of this upload.
public struct OutboxAttachment: Codable, Equatable, Sendable {
  let file: String
  public let name: String
  let mimeType: String
  let size: Int
  let key: String
}

/// Everything about a queued letter. Stored as one encrypted blob: nothing that says who a letter is
/// to, or what it says, is readable on disk.
public struct OutboxPayload: Codable, Equatable, Sendable {
  public let prisonerId: Int
  public let prisonerName: String
  /// A group member writing for someone: the name shown as "Writing as".
  public let writingAs: String?
  public let body: String
  public let relayNote: String?
  public let relayChapter: Int?
  public let asWriterId: Int?
  public let fromPrisoner: Bool
  let groupRelaysFacility: Bool
  public internal(set) var attachments: [OutboxAttachment]
  /// Made when the letter is queued (or carried over from the compose screen's failed attempt) and sent with
  /// every try. It is what lets the server answer "I already have that one" instead of mailing a second copy.
  public let idempotencyKey: String

  var newLetter: NewLetter {
    NewLetter(prisonerId: prisonerId, body: body, relayNote: relayNote, relayChapter: relayChapter, asWriterId: asWriterId, fromPrisoner: fromPrisoner, groupRelaysFacility: groupRelaysFacility, idempotencyKey: idempotencyKey)
  }
}

/// A queued letter as screens see it.
public struct OutboxItem: Identifiable, Equatable, Sendable {
  public let id: String
  public let payload: OutboxPayload
  public let queuedAt: Date
  /// Nil while waiting. Otherwise the server's reason, and the letter needs the writer's attention.
  public let problem: String?
  /// The server has the letter; only files are outstanding or were refused.
  public let letterWasSent: Bool
}

public struct FlushOutcome: Equatable, Sendable {
  public var sent = 0
  public var refused = 0
  public var stillWaiting = 0
}

/// Letters written without a connection.
///
/// The rule that shapes everything here is that a prisoner must never get the same letter twice.
/// Every queued letter, and every file with it, carries an `Idempotency-Key` made once and repeated on
/// each retry (API PR #97): if an earlier attempt did arrive, the server hands back that letter instead
/// of creating another. The letter and its files are still separate steps, each recorded the moment it
/// succeeds, so a retry resumes where the last one stopped.
///
/// In end-to-end mode a letter cannot be sealed offline (sealing needs the relay group's current
/// public key), so it waits here encrypted under a key in the Keychain, as drafts do, and is sealed
/// when it is sent. Letters belong to the account that wrote them and survive sign-out; only that
/// account's session ever sends them.
@MainActor @Observable
public final class OutboxRepository {
  /// The signed-in account's queued letters, oldest first. Empty when signed out.
  public private(set) var items: [OutboxItem] = []

  @ObservationIgnored private let directory: URL
  @ObservationIgnored private let cipher: SecretCipher
  @ObservationIgnored private let files: LocalFiles
  @ObservationIgnored private let letters: LettersRepository
  @ObservationIgnored private let sessions: SessionRepository
  @ObservationIgnored private var flushing: Task<FlushOutcome, Never>?
  @ObservationIgnored private var monitor: NWPathMonitor?
  /// Called after a flush that the person did not ask for (the network came back), so the app can say what happened.
  @ObservationIgnored public var onBackgroundFlush: (@MainActor (FlushOutcome) -> Void)?

  /// What is on disk for one letter, sealed whole.
  private struct Entry: Codable {
    let id: String
    var payload: OutboxPayload
    let queuedAt: Date
    var refusedBecause: String?
    var attempts = 0
    /// Set as soon as the server has the letter, so a retry carries on with its files and never posts it twice.
    var messageId: Int?
  }

  init(directory: URL, cipher: SecretCipher, files: LocalFiles, letters: LettersRepository, sessions: SessionRepository) {
    self.directory = directory
    self.cipher = cipher
    self.files = files
    self.letters = letters
    self.sessions = sessions
    sessions.onSignedOut.append { [weak self] in self?.items = [] }
    reload()
  }

  private var myId: Int? { sessions.state.user?.id }

  // MARK: Storage: one sealed file per letter, in a folder per account

  private func folder(_ userId: Int) -> URL {
    let dir = directory.appendingPathComponent(String(userId), isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var values = URLResourceValues()
    values.isExcludedFromBackup = true // the key never leaves this phone, so a backed-up copy could never be opened
    var root = directory
    try? root.setResourceValues(values)
    return dir
  }

  private func url(_ id: String, _ userId: Int) -> URL { folder(userId).appendingPathComponent("\(id).letter") }

  private func read(_ url: URL) -> Entry? {
    guard let blob = try? Data(contentsOf: url), let plain = try? cipher.decrypt(blob) else { return nil }
    return try? JSONDecoder().decode(Entry.self, from: plain)
  }

  private func write(_ entry: Entry, _ userId: Int) {
    guard let blob = try? cipher.encrypt(JSONEncoder().encode(entry)) else { return }
    try? blob.write(to: url(entry.id, userId), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
  }

  private func remove(_ entry: Entry, _ userId: Int) {
    entry.payload.attachments.forEach { try? FileManager.default.removeItem(at: folder(userId).appendingPathComponent($0.file)) }
    try? FileManager.default.removeItem(at: url(entry.id, userId))
  }

  private func entries(_ userId: Int) -> [Entry] {
    let urls = (try? FileManager.default.contentsOfDirectory(at: folder(userId), includingPropertiesForKeys: nil)) ?? []
    return urls.filter { $0.pathExtension == "letter" }.compactMap(read).sorted { ($0.queuedAt, $0.id) < ($1.queuedAt, $1.id) }
  }

  /// Reads the signed-in account's letters from disk. Call when the account changes.
  public func reload() {
    items = myId.map { id in
      entries(id).map { OutboxItem(id: $0.id, payload: $0.payload, queuedAt: $0.queuedAt, problem: $0.refusedBecause, letterWasSent: $0.messageId != nil) }
    } ?? []
  }

  public var hasWaiting: Bool { items.contains { $0.problem == nil } }

  // MARK: Queueing and editing

  @discardableResult
  public func queue(prisonerName: String, writingAs: String?, letter: NewLetter, attachments: [StagedFile]) throws -> String {
    guard let userId = myId else { throw AppError.unauthorized("You are signed out.") }
    let id = UUID().uuidString
    var stored: [OutboxAttachment] = []
    for (n, staged) in attachments.enumerated() {
      // Out of the cache (which iOS may empty) and encrypted, because it may sit here for days.
      let name = "\(id)-\(n).file"
      guard let bytes = try? Data(contentsOf: staged.url), let sealed = try? cipher.encrypt(bytes),
            (try? sealed.write(to: folder(userId).appendingPathComponent(name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])) != nil
      else { throw AppError.unexpected("Could not keep \(staged.name) for later.") }
      files.discard(staged)
      stored.append(OutboxAttachment(file: name, name: staged.name, mimeType: staged.mimeType, size: staged.size, key: UUID().uuidString))
    }
    // The compose screen's key if it already tried with one: that attempt may have arrived, and the same key is how the server will know.
    let payload = OutboxPayload(
      prisonerId: letter.prisonerId, prisonerName: prisonerName, writingAs: writingAs, body: letter.body, relayNote: letter.relayNote, relayChapter: letter.relayChapter,
      asWriterId: letter.asWriterId, fromPrisoner: letter.fromPrisoner, groupRelaysFacility: letter.groupRelaysFacility, attachments: stored,
      idempotencyKey: letter.idempotencyKey ?? UUID().uuidString
    )
    write(Entry(id: id, payload: payload, queuedAt: Date()), userId)
    reload()
    return id
  }

  /// For editing: the letter, with its files decrypted back into staging.
  public func open(_ id: String) -> (payload: OutboxPayload, files: [StagedFile])? {
    guard let userId = myId, let entry = read(url(id, userId)) else { return nil }
    return (entry.payload, entry.payload.attachments.compactMap { unsealFile($0, userId) })
  }

  private func unsealFile(_ a: OutboxAttachment, _ userId: Int) -> StagedFile? {
    guard let sealed = try? Data(contentsOf: folder(userId).appendingPathComponent(a.file)), let plain = try? cipher.decrypt(sealed) else { return nil }
    return try? files.stage(data: plain, name: a.name, mimeType: a.mimeType)
  }

  /// Also what the compose screen calls after re-sending an opened letter: the new send has superseded it.
  public func delete(_ id: String) {
    guard let userId = myId, let entry = read(url(id, userId)) else { return }
    remove(entry, userId)
    reload()
  }

  /// Every letter one account has waiting, files and all, when that account is deleted.
  func deleteAll(userId: Int) {
    try? FileManager.default.removeItem(at: directory.appendingPathComponent(String(userId), isDirectory: true))
    reload()
  }

  /// Puts a refused letter back in line, unchanged (the reason may have been temporary: a suspended group, say).
  public func retry(_ id: String) {
    guard let userId = myId, var entry = read(url(id, userId)) else { return }
    entry.refusedBecause = nil
    write(entry, userId)
    reload()
  }

  // MARK: Sending

  /// Sends what can be sent now. Safe to call at any time and from anywhere; runs one at a time.
  @discardableResult
  public func flush() async -> FlushOutcome {
    if let flushing { _ = await flushing.value }
    let task = Task { await self.reallyFlush() }
    flushing = task
    let outcome = await task.value
    if flushing == task { flushing = nil }
    return outcome
  }

  private func reallyFlush() async -> FlushOutcome {
    guard let userId = myId else { return FlushOutcome() }
    var outcome = FlushOutcome()
    sending: for entry in entries(userId) where entry.refusedBecause == nil {
      switch await sendOne(entry, userId) {
      case .sent: outcome.sent += 1
      case .refused: outcome.refused += 1
      case .dropped: break
      // No point trying the next letter through the same broken connection, and order matters to a reader.
      case .later: break sending
      }
    }
    if myId == userId { reload() }
    outcome.stillWaiting = entries(userId).filter { $0.refusedBecause == nil }.count
    return outcome
  }

  private enum Step { case sent, refused, later, dropped }

  private func sendOne(_ start: Entry, _ userId: Int) async -> Step {
    var entry = start
    entry.attempts += 1
    write(entry, userId)

    // 1. The letter itself. The key makes a repeat harmless; `messageId` makes it unnecessary.
    if entry.messageId == nil {
      do {
        entry.messageId = try await letters.send(entry.payload.newLetter).id
        write(entry, userId)
      } catch {
        let e = AppError.from(error)
        // Sent earlier, and deleted since (by the writer, on another device): it must not be sent again, and there is nothing to say.
        if e.isGone { remove(entry, userId); return .dropped }
        guard let reason = Self.refusal(e) else { return .later }
        return refuse(entry, userId, reason)
      }
    }

    // 2. Its files, each at most once: a file that went up is struck off before the next is tried.
    guard let messageId = entry.messageId else { return .later }
    for attachment in entry.payload.attachments {
      guard let staged = unsealFile(attachment, userId) else {
        return refuse(entry, userId, "The letter was sent, but \(attachment.name) could not be attached: the file could not be read back from this phone.")
      }
      defer { files.discard(staged) }
      do {
        _ = try await letters.upload(messageId: messageId, staged: staged, idempotencyKey: attachment.key)
        try? FileManager.default.removeItem(at: folder(userId).appendingPathComponent(attachment.file))
        entry.payload.attachments.removeAll { $0 == attachment }
        write(entry, userId)
      } catch {
        guard let reason = Self.refusal(.from(error)) else { return .later }
        return refuse(entry, userId, "The letter was sent, but \(attachment.name) could not be attached: \(reason)")
      }
    }
    remove(entry, userId)
    return .sent
  }

  private func refuse(_ entry: Entry, _ userId: Int, _ reason: String) -> Step {
    var refused = entry
    refused.refusedBecause = reason
    write(refused, userId)
    return .refused
  }

  /// Nil means "try again when things change": with idempotency keys it no longer matters whether the
  /// last attempt arrived. A sentence means the server understood and said no; trying again unchanged
  /// would get the same answer.
  static func refusal(_ error: AppError) -> String? {
    switch error {
    case .network, .unreadable, .server, .unexpected, .rateLimited: return nil // no answer, a 5xx, a Wi-Fi login page
    case .unauthorized: return nil // signed out: it waits for the next sign-in
    case _ where error.isStillProcessing: return nil // our own earlier attempt is still in flight
    case _ where error == .lettersLocked: return nil // waits for the password
    default: return error.userMessage ?? "The server refused this letter without saying why."
    }
  }

  // MARK: When the network comes back

  /// Watches the connection while the app is running, and sends what is waiting the moment there is
  /// one. (When the app is not running, the app target's background task does the same; see `ABCMailboxApp`.)
  public func startWatchingNetwork() {
    guard monitor == nil else { return }
    let monitor = NWPathMonitor()
    monitor.pathUpdateHandler = { [weak self] path in
      guard path.status == .satisfied else { return }
      Task { @MainActor in
        guard let self, self.hasWaiting else { return }
        let outcome = await self.flush()
        self.onBackgroundFlush?(outcome)
      }
    }
    monitor.start(queue: .global(qos: .utility))
    self.monitor = monitor
  }
}
