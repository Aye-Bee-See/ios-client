import ABCCrypto
import Foundation

/// What the compose screen sends. `relayChapter` nil lets the server resolve it.
public struct NewLetter: Sendable {
  public let prisonerId: Int
  public let body: String
  public let relayNote: String?
  public let relayChapter: Int?
  /// Group accounts: the managed writer this letter is from; nil means the group's anonymous writer (or, for a writer, themselves).
  public let asWriterId: Int?
  /// Group accounts: this is a prisoner's reply being recorded on `asWriterId`'s thread.
  public let fromPrisoner: Bool
  /// Group accounts, end-to-end: the group is a relay group of this facility, so the server lets it hold an envelope.
  public let groupRelaysFacility: Bool
  /// Made up once per letter and repeated on every retry of it (API PR #97). A retry of a letter that
  /// did arrive gets that letter back instead of creating a second one for the prisoner.
  public let idempotencyKey: String?

  public init(prisonerId: Int, body: String, relayNote: String?, relayChapter: Int?, asWriterId: Int? = nil, fromPrisoner: Bool = false, groupRelaysFacility: Bool = false, idempotencyKey: String? = nil) {
    self.prisonerId = prisonerId
    self.body = body
    self.relayNote = relayNote
    self.relayChapter = relayChapter
    self.asWriterId = asWriterId
    self.fromPrisoner = fromPrisoner
    self.groupRelaysFacility = groupRelaysFacility
    self.idempotencyKey = idempotencyKey
  }
}

public struct LetterEdit: Sendable {
  public let messageId: Int
  public let body: String
  public let relayNote: String?
  public let relayChapter: Int?

  public init(messageId: Int, body: String, relayNote: String?, relayChapter: Int?) {
    self.messageId = messageId
    self.body = body
    self.relayNote = relayNote
    self.relayChapter = relayChapter
  }
}

/// Turns letters into what the API wants and back. In server mode that is a
/// pass-through of `messageText`; in end-to-end mode the body and note are
/// encrypted on the device under a fresh content key, the key is sealed to
/// each reader, and incoming letters are opened with the caller's envelope.
/// Repositories use this and never know which mode is active.
@MainActor
final class LetterCodec {
  private let modes: EncryptionModeRepository
  private let vault: KeyVault
  private let sessions: SessionRepository
  private let api: APIClient
  private let keyring: GroupKeyring

  init(modes: EncryptionModeRepository, vault: KeyVault, sessions: SessionRepository, api: APIClient, keyring: GroupKeyring) {
    self.modes = modes
    self.vault = vault
    self.sessions = sessions
    self.api = api
    self.keyring = keyring
  }

  private var viewer: SessionUser? { sessions.state.user }

  /// Call before decoding anything. For a group member on an end-to-end server it
  /// loads the group key and the custody keys once, so `incoming` and `preview`
  /// can stay plain functions; for everyone else it returns at once.
  func ready() async { if viewer?.isStaff == true, await isEndToEnd() { await keyring.load() } }

  /// After a 409 KeyVersionError: some group rotated its key, possibly ours, so open it again before re-sealing.
  func refreshKeys() async { if viewer?.isStaff == true { await keyring.load(force: true) } }

  func isEndToEnd() async -> Bool { await modes.current() == .e2e }

  /// The request for a new letter; in end-to-end mode also the content key, for encrypting its attachments.
  func outgoing(_ letter: NewLetter) async throws -> (request: SendMessageRequest, contentKey: Data?) {
    let sender = letter.fromPrisoner ? "prisoner" : "user"
    // A reply is not relayed anywhere, so it carries no relay group or note.
    let relayChapter = letter.fromPrisoner ? nil : letter.relayChapter
    let note = letter.fromPrisoner ? nil : letter.relayNote?.nonBlank
    var request = SendMessageRequest(prisoner: letter.prisonerId, sender: sender, user: letter.asWriterId, relayChapter: relayChapter)
    guard await isEndToEnd() else {
      request.messageText = letter.body
      request.relayNote = note
      return (request, nil)
    }

    guard let user = viewer else { throw AppError.unauthorized("You are signed out.") }
    var readers: [Reader] = []
    if user.isStaff {
      // A group member writes as the group: anonymously, for a writer it manages, or recording a reply.
      let group = try Self.key(from: await keyring.load())
      if let writerId = letter.asWriterId {
        if let writerKey = try await publicKey(user: writerId).key {
          readers.append(Reader(type: Reader.user, id: writerId, publicKey: writerKey))
        } else if !letter.fromPrisoner {
          // A letter written *for* someone is theirs, and needs their key.
          throw Self.writerHasNoKey
        }
        // A reply may be recorded for a writer who has no key yet (API PR #95): it is sealed to the group
        // alone, and a member's phone adds the writer's envelope once they have a key (`GroupRepository.setUpKeys`).
      }
      // The group keeps its own envelope wherever the server permits one: as the manager of the writer
      // (which includes its anonymous writer), or as a relay group of the facility.
      let managesWriter = letter.asWriterId.map { keyring.writerKey($0) != nil } ?? true
      if managesWriter || letter.groupRelaysFacility || letter.relayChapter == group.groupId || readers.isEmpty {
        readers.append(Reader(type: Reader.chapter, id: group.groupId, publicKey: group.publicKey, keyVersion: group.version))
      }
    } else {
      guard let keyPair = vault.keyPair(for: user.id) else { throw AppError.lettersLocked }
      readers.append(Reader(type: Reader.user, id: user.id, publicKey: Sodium.toBase64(keyPair.publicKey)))
    }
    if let groupId = relayChapter, !readers.contains(where: { $0.type == Reader.chapter && $0.id == groupId }) {
      let relay = try await publicKey(chapter: groupId)
      guard let relayKey = relay.key else {
        throw AppError.validation(["That relay group has not set up encryption yet, so it cannot receive letters. Choose another group or ask them to finish setting up."])
      }
      readers.append(Reader(type: Reader.chapter, id: groupId, publicKey: relayKey, keyVersion: relay.version))
    }

    let enc = try Self.sealing { try LetterCipher.encrypt(body: letter.body, relayNote: note, readers: readers) }
    request.ciphertext = enc.body.ciphertext
    request.nonce = enc.body.nonce
    request.relayNoteCiphertext = enc.relayNote?.ciphertext
    request.relayNoteNonce = enc.relayNote?.nonce
    request.envelopes = enc.envelopes.map { EnvelopeDTO(readerType: $0.readerType, readerId: $0.readerId, wrappedKey: $0.wrappedKey, keyVersion: $0.keyVersion) }
    return (request, enc.contentKey)
  }

  /// An edit re-encrypts under the letter's existing content key, so its envelopes stay valid.
  func edit(_ edit: LetterEdit, existing: MessageDTO) throws -> UpdateMessageRequest {
    var request = UpdateMessageRequest(id: edit.messageId)
    guard existing.ciphertext != nil else {
      request.messageText = edit.body
      request.relayNote = edit.relayNote
      request.relayChapter = edit.relayChapter
      return request
    }
    guard let key = contentKey(existing) else { throw AppError.lettersLocked }
    let body = try Self.sealing { try LetterCipher.encryptText(edit.body, contentKey: key) }
    let note = try Self.sealing { try edit.relayNote?.nonBlank.map { try LetterCipher.encryptText($0, contentKey: key) } }
    // The reader set is fixed after sending in end-to-end mode, so the relay group is not sent.
    request.ciphertext = body.ciphertext
    request.nonce = body.nonce
    request.relayNoteCiphertext = note?.ciphertext
    request.relayNoteNonce = note?.nonce
    return request
  }

  func incoming(_ dto: MessageDTO) -> Letter {
    var letter = dto.toDomain()
    guard let ciphertext = dto.ciphertext, let nonce = dto.nonce else { return letter }
    guard let key = contentKey(dto), let body = try? LetterCipher.decryptText(ciphertext: ciphertext, nonce: nonce, contentKey: key) else {
      // No envelope at all is "not shared with you yet"; an envelope this phone cannot open is "locked".
      if dto.envelopes?.isEmpty ?? true, viewer?.isStaff == false { letter.awaitingShare = true } else { letter.locked = true }
      return letter
    }
    letter.body = body
    letter.relayNote = nil
    if let noteCiphertext = dto.relayNoteCiphertext, let noteNonce = dto.relayNoteNonce {
      guard let note = try? LetterCipher.decryptText(ciphertext: noteCiphertext, nonce: noteNonce, contentKey: key) else {
        letter.body = ""
        letter.locked = true
        return letter
      }
      letter.relayNote = note
    }
    return letter
  }

  func preview(_ dto: LastMessageDTO) -> String? {
    guard let ciphertext = dto.ciphertext, let nonce = dto.nonce else { return dto.messageText?.nonBlank }
    guard let key = openMine(dto.envelopes) else { return nil }
    return try? LetterCipher.decryptText(ciphertext: ciphertext, nonce: nonce, contentKey: key)
  }

  /// The letter's content key, from the envelope sealed to this account. Nil when locked or not a reader.
  func contentKey(_ dto: MessageDTO) -> Data? { openMine(dto.envelopes) }

  /// A writer has one way in: the envelope sealed to them. A group member has up to three:
  /// their own, the group's, and those of writers whose keys the group holds in custody.
  private func openMine(_ envelopes: [EnvelopeDTO]?) -> Data? {
    guard let user = viewer, let envelopes, !envelopes.isEmpty else { return nil }
    let group = user.isStaff ? keyring.groupKey() : nil
    for e in envelopes {
      let keyPair: Sodium.KeyPair?
      if e.readerType == Reader.user, e.readerId == user.id { keyPair = vault.keyPair(for: user.id) }
      else if e.readerType == Reader.chapter, let group, e.readerId == group.groupId { keyPair = group.keyPair }
      else if e.readerType == Reader.user, group != nil { keyPair = keyring.writerKey(e.readerId) }
      else { keyPair = nil }
      if let keyPair, let key = try? LetterCipher.openEnvelope(e.wrappedKey, keyPair: keyPair) { return key }
    }
    return nil
  }

  /// Base64 public key and, for groups, the key version. A rotation makes a cached copy wrong, so this always asks.
  private func publicKey(user: Int? = nil, chapter: Int? = nil) async throws -> (key: String?, version: Int?) {
    let envelope: APIEnvelope<PublicKeyDTO> = try await api.get("auth/public-key", query: [("user", user.map(String.init)), ("chapter", chapter.map(String.init))])
    return (envelope.data?.publicKey, envelope.data?.keyVersion)
  }

  /// Forwarding: one more envelope for a partner relay group, sealed from the content key this
  /// reader already holds. The letter itself is never re-encrypted.
  func envelope(for dto: MessageDTO, groupId: Int) async throws -> EnvelopeDTO {
    await ready()
    guard let key = contentKey(dto) else { throw AppError.lettersLocked }
    let partner = try await publicKey(chapter: groupId)
    guard let partnerKey = partner.key else { throw AppError.validation(["That group has not set up encryption yet, so it cannot be given this letter."]) }
    let sealed = try Self.sealing { try LetterCipher.seal(contentKey: key, to: Reader(type: Reader.chapter, id: groupId, publicKey: partnerKey, keyVersion: partner.version)) }
    return EnvelopeDTO(readerType: sealed.readerType, readerId: sealed.readerId, wrappedKey: sealed.wrappedKey, keyVersion: sealed.keyVersion)
  }

  static let writerHasNoKey = AppError.validation(["This writer has no encryption key yet, so nothing can be sealed to them. They get one the first time they sign in."])

  /// The opened group key, or a sentence for the reason a group member cannot use it yet.
  static func key(from state: GroupKeyState) throws -> GroupKey {
    switch state {
    case .ready(let key): return key
    case .failed(let error): throw error
    case .locked: throw AppError.lettersLocked
    case .notSetUp: throw AppError.forbidden("Your group has not set up its encryption key yet. Open the Inbox and choose \"Set up the group key\".")
    case .notHeld: throw AppError.forbidden("You have not been given your group's key yet. Ask a member who holds it to hand it to you from their Inbox.")
    case .notNeeded: throw AppError.forbidden("This account is not a member of a group.")
    }
  }

  /// A published key that is not a key (bad base64, wrong length) should read as a sentence, not a crash.
  static func sealing<T>(_ work: () throws -> T) throws -> T {
    do { return try work() } catch let e as AppError { throw e } catch { throw AppError.unexpected("A published encryption key could not be used: \(error)") }
  }
}
