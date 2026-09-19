import ABCCrypto
import Foundation

/// What a support group member does: the print queue, status moves, the writers
/// the group looks after, and (on an end-to-end server) the group's own key.
@MainActor
public final class GroupRepository {
  private let api: APIClient
  private let letters: LettersRepository
  private let directory: DirectoryRepository
  private let codec: LetterCodec
  private let keyring: GroupKeyring
  private let engine: CryptoEngine
  private let vault: KeyVault
  private let sessions: SessionRepository

  init(api: APIClient, letters: LettersRepository, directory: DirectoryRepository, codec: LetterCodec, keyring: GroupKeyring, engine: CryptoEngine, vault: KeyVault, sessions: SessionRepository) {
    self.api = api
    self.letters = letters
    self.directory = directory
    self.codec = codec
    self.keyring = keyring
    self.engine = engine
    self.vault = vault
    self.sessions = sessions
  }

  private var viewer: SessionUser? { sessions.state.user }

  /// The opened group key, or the reason it is not available as an error a screen can show.
  private func groupKey(force: Bool = false) async throws -> GroupKey {
    switch await keyring.load(force: force) {
    case .notSetUp: throw AppError.forbidden("Your group has not set up its encryption key yet. Do that first, from the Inbox.")
    case .notHeld: throw AppError.forbidden("You have not been given your group's key yet. Ask a member who holds it to hand it to you.")
    case let state: return try LetterCodec.key(from: state)
    }
  }

  // Queue rows name the prisoner by id only, so each distinct prisoner is fetched once and remembered.
  private var prisoners: [Int: Prisoner] = [:]
  private func prisoner(_ id: Int) async -> Prisoner? {
    if let known = prisoners[id] { return known }
    let fetched = try? await directory.prisoner(id: id)
    prisoners[id] = fetched
    return fetched
  }

  /// Letters the group relays, in one status. Each comes with the prisoner, for addressing.
  public func queue(groupId: Int, status: LetterStatus, page: Int, pageSize: Int) async throws -> Page<QueueItem> {
    await codec.ready()
    let envelope: APIEnvelope<[MessageDTO]> = try await api.get("messaging/messages", query: [
      ("relayChapter", String(groupId)), ("status", status.key), ("page", String(page)), ("page_size", String(pageSize)),
    ])
    let page: Page<MessageDTO> = envelope.toPage()
    var items: [QueueItem] = []
    for dto in page.items { items.append(QueueItem(letter: codec.incoming(dto), prisoner: await prisoner(dto.prisoner))) }
    return Page(items: items, total: page.total, page: page.page, pageSize: page.pageSize)
  }

  public func queueItem(messageId: Int) async throws -> QueueItem {
    let letter = try await letters.letter(messageId: messageId)
    var found: Prisoner?
    if let id = letter.prisonerId { found = await prisoner(id) }
    return QueueItem(letter: letter, prisoner: found)
  }

  /// Forward only: queued, printed, mailed. Anything else is a 409 whose sentence says why.
  public func setStatus(messageId: Int, status: LetterStatus) async throws -> Letter {
    await codec.ready()
    let envelope: APIEnvelope<MessageDTO> = try await api.send("PUT", "messaging/status", body: StatusRequest(id: messageId, status: status.key))
    return codec.incoming(try envelope.required("letter"))
  }

  private func writerRows() async throws -> [WriterDTO] {
    let envelope: APIEnvelope<[WriterDTO]> = try await api.get("auth/writers", query: [("page_size", "100")])
    return envelope.data ?? []
  }

  public func writers() async throws -> [ManagedWriter] {
    try await writerRows().filter { $0.anonymousForChapter == nil }.map { $0.toDomain() }.sorted { $0.name.lowercased() < $1.name.lowercased() }
  }

  public func addWriter(name: String, email: String?, note: String?) async throws -> ManagedWriter {
    var request = AddWriterRequest(name: name.trimmed, email: email?.trimmed.nonBlank, managerNote: note?.trimmed.nonBlank)
    guard await codec.isEndToEnd() else {
      let envelope: APIEnvelope<WriterDTO> = try await api.send("POST", "auth/writer", body: request)
      return try envelope.required("writer").toDomain()
    }
    // End-to-end: the writer's keypair is made here and the private half sealed to the group (custody),
    // so the group can write and read for them until they claim the account. A 409 means the group key
    // was rotated since this device opened it: open the new one and seal again, once.
    for attempt in 0..<2 {
      let group = try await groupKey(force: attempt == 1)
      let made = try LetterCodec.sealing { try GroupKeys.createSealed(to: group.publicKey) }
      request.publicKey = made.publicKey
      request.orgWrappedPrivateKey = made.sealedPrivateKey
      request.orgKeyVersion = group.version
      do {
        let envelope: APIEnvelope<WriterDTO> = try await api.send("POST", "auth/writer", body: request)
        let writer = try envelope.required("writer").toDomain()
        keyring.remember(writerId: writer.id, keyPair: made.keyPair)
        return writer
      } catch let e as AppError where e.isConflict && attempt == 0 {
        continue
      }
    }
    throw AppError.unexpected("unreachable")
  }

  public func issueToken(writerId: Int) async throws -> IssuedToken {
    guard await codec.isEndToEnd() else {
      let envelope: APIEnvelope<IssuedTokenDTO> = try await api.send("POST", "auth/writer/token", body: IssueTokenRequest(writer: writerId))
      guard let token = envelope.data?.token else { throw AppError.unexpected("The server did not return a token.") }
      return IssuedToken(token: token, expiresAt: envelope.data?.expiresAt.instant)
    }
    // End-to-end: the token is a secret the server must never see. It is made here, the writer's private
    // key is wrapped under it, and the server gets the wrapped key and a hash to recognise the token by.
    let writerKey = try await custodyKey(writerId: writerId)
    let made = try await LetterCodec.sealingAsync { try await self.engine.newClaimToken(writerPrivateKey: writerKey.privateKey) }
    let request = IssueTokenRequest(writer: writerId, tokenHash: made.tokenHash, claimWrappedPrivateKey: made.wrapped.wrapped, claimSalt: made.wrapped.salt, claimKdfParams: made.wrapped.params)
    let envelope: APIEnvelope<IssuedTokenDTO> = try await api.send("POST", "auth/writer/token", body: request)
    return IssuedToken(token: made.token, expiresAt: envelope.data?.expiresAt.instant)
  }

  /// The keypair of a writer in custody. A writer made before the server was end-to-end has none;
  /// the API lets the managing group give them one, once, and this does.
  private func custodyKey(writerId: Int) async throws -> Sodium.KeyPair {
    let group = try await groupKey()
    if let known = keyring.writerKey(writerId) { return known }
    guard let writer = try await writerRows().first(where: { $0.id == writerId }) else { throw AppError.notFound("That writer is no longer managed by your group.") }
    if let publicKey = writer.publicKey {
      guard let sealed = writer.orgWrappedPrivateKey else { throw AppError.forbidden("This writer's key is not held by your group, so a token cannot be made for them.") }
      guard let opened = try? GroupKeys.open(sealed, holder: group.keyPair, expectedPublicKey: publicKey) else {
        throw AppError.forbidden("This writer's key was sealed to an earlier group key and cannot be opened. Rotate the group key on the web to repair it.")
      }
      keyring.remember(writerId: writerId, keyPair: opened)
      return opened
    }
    let made = try LetterCodec.sealing { try GroupKeys.createSealed(to: group.publicKey) }
    try await api.send("PUT", "auth/user", body: UpdateUserRequest(id: writerId, publicKey: made.publicKey, orgWrappedPrivateKey: made.sealedPrivateKey, orgKeyVersion: group.version))
    keyring.remember(writerId: writerId, keyPair: made.keyPair)
    return made.keyPair
  }

  public func revokeToken(writerId: Int) async throws {
    try await api.send("DELETE", "auth/writer/token", body: WriterRef(writer: writerId))
  }

  // MARK: - End-to-end mode only

  /// Where this member stands with the group key. Always `notNeeded` in server mode.
  public var keyState: GroupKeyState { keyring.state }

  @discardableResult
  public func refreshKeyState() async -> GroupKeyState { await keyring.load(force: true) }

  /// Makes the group's keypair on this device, once, and seals the private half to this member.
  public func setUpGroupKey() async throws {
    guard let user = viewer else { throw AppError.unauthorized("You are signed out.") }
    guard let groupId = user.chapterId else { throw AppError.forbidden("This account is not a member of a group.") }
    guard let mine = vault.keyPair(for: user.id) else { throw AppError.lettersLocked }
    let made = try LetterCodec.sealing { try GroupKeys.createSealed(to: Sodium.toBase64(mine.publicKey)) }
    defer { made.keyPair.wipe() }
    // Success or not, ask again: on a 409 another member set the key up first, and the state should say so.
    do {
      try await api.send("PUT", "auth/chapter-keys", body: GroupKeyRequest(chapter: groupId, publicKey: made.publicKey, wrappedOrgPrivateKey: made.sealedPrivateKey))
    } catch {
      await keyring.load(force: true)
      throw error
    }
    await keyring.load(force: true)
  }

  private func memberRows(groupId: Int) async throws -> [MemberDTO] {
    let envelope: APIEnvelope<MemberKeysDTO> = try await api.get("auth/member-keys", query: [("chapter", String(groupId))])
    return envelope.data?.members ?? []
  }

  /// The group's members and whether each holds the group key.
  public func members() async throws -> [GroupMember] {
    guard let user = viewer else { throw AppError.unauthorized("You are signed out.") }
    guard let groupId = user.chapterId else { return [] }
    return try await memberRows(groupId: groupId).map {
      GroupMember(id: $0.id, name: $0.name?.nonBlank ?? $0.username ?? "Member \($0.id)", hasOwnKey: $0.publicKey != nil, holdsGroupKey: $0.holdsGroupKey ?? false, isMe: $0.id == user.id)
    }
  }

  /// A key holder hands the group key to another member, sealed to that member's public key.
  public func handKey(to memberId: Int) async throws {
    let group = try await groupKey()
    // Their public key comes from the members list, which only this group and admins can read.
    guard let theirKey = try await memberRows(groupId: group.groupId).first(where: { $0.id == memberId })?.publicKey else {
      throw AppError.validation(["That member has no key of their own yet. They get one the first time they sign in; hand them the group key after that."])
    }
    let sealed = try LetterCodec.sealing { try GroupKeys.sealPrivateKey(group.keyPair.privateKey, to: theirKey) }
    try await api.send("PUT", "auth/member-key", body: MemberKeyRequest(chapter: group.groupId, user: memberId, wrappedOrgPrivateKey: sealed))
  }

  /// Stops handing the key out. It cannot take back a key already opened; that needs a rotation.
  public func stopHandingKey(to memberId: Int) async throws {
    guard let groupId = viewer?.chapterId else { throw AppError.forbidden("This account is not a member of a group.") }
    try await api.send("DELETE", "auth/member-key", body: MemberRef(chapter: groupId, user: memberId))
  }

  /// The facility's other relay groups: the only groups the server lets a letter be shared with. Empty in server mode.
  public func partners(forPrisoner prisonerId: Int) async -> [SupportGroup] {
    guard let mine = keyring.groupKey()?.groupId, let facilityId = await prisoner(prisonerId)?.facilityId, let facility = try? await directory.facility(id: facilityId) else { return [] }
    return facility.relayGroups.filter { $0.id != mine && $0.isActive }
  }

  /// Gives a partner relay group the means to read one letter.
  public func share(messageId: Int, withGroup partnerGroupId: Int) async throws {
    let dto = try await letters.message(messageId)
    let e = try await codec.envelope(for: dto, groupId: partnerGroupId)
    try await api.send("POST", "messaging/envelope", body: AddEnvelopeRequest(message: messageId, readerType: e.readerType, readerId: e.readerId, wrappedKey: e.wrappedKey, keyVersion: e.keyVersion))
  }
}
