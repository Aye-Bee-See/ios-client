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
    switch await keyring.load(force: force, anyMode: true) {
    case .notSetUp: throw AppError.forbidden("Your group has not set up its encryption key yet. Do that first, from the Inbox.")
    case .notHeld: throw AppError.forbidden("You have not been given your group's key yet. Ask the group admin in charge of it to hand it to you, from their Inbox, Group key.")
    case let state: return try LetterCodec.key(from: state)
    }
  }

  // Since API PR #111 a queue row read with `full=true` brings its prisoner and facility with it. Against an older
  // API a row names the prisoner by id only, and then each distinct prisoner is fetched once and remembered, as before.
  private var prisoners: [Int: Prisoner] = [:]
  private func prisoner(_ id: Int) async -> Prisoner? {
    if let known = prisoners[id] { return known }
    let fetched = try? await directory.prisoner(id: id)
    prisoners[id] = fetched
    return fetched
  }

  /// Letters the group relays, in one status. Each comes with the prisoner, for addressing.
  public func queue(groupId: Int, status: LetterStatus, page: Int, pageSize: Int) async throws -> Page<QueueItem> {
    try await queue(groupId: groupId, query: [("status", status.key)], page: page, pageSize: pageSize)
  }

  private func queue(groupId: Int, query: [(String, String?)], page: Int, pageSize: Int) async throws -> Page<QueueItem> {
    await codec.ready()
    let envelope: APIEnvelope<[MessageDTO]> = try await api.get("messaging/messages", query: [("relayChapter", String(groupId))] + query + [("full", "true"), ("page", String(page)), ("page_size", String(pageSize))])
    let page: Page<MessageDTO> = envelope.toPage()
    var items: [QueueItem] = []
    for dto in page.items { items.append(await queueItem(dto)) }
    return Page(items: items, total: page.total, page: page.page, pageSize: page.pageSize)
  }

  private func queueItem(_ dto: MessageDTO) async -> QueueItem {
    let letter = codec.incoming(dto)
    if let details = dto.prisonerDetails { return QueueItem(letter: letter, prisoner: details.toDomain()) }
    return QueueItem(letter: letter, prisoner: await prisoner(dto.prisoner))
  }

  public func queueItem(messageId: Int) async throws -> QueueItem {
    await codec.ready()
    return await queueItem(try await letters.message(messageId))
  }

  /// The most the API moves in one request. More than that would stop being all-or-none, so it is refused, not split quietly.
  public static let batchLimit = 200

  /// Moves several letters together, all or none (API PR #111), and answers how many moved. A refusal names the
  /// letter that stopped the rest, and nothing has changed. Held letters are not for this: each one is a decision.
  public func setStatusOfMany(messageIds: [Int], status: LetterStatus) async throws -> Int {
    var ids: [Int] = []
    for id in messageIds where !ids.contains(id) { ids.append(id) }
    guard !ids.isEmpty else { return 0 }
    guard ids.count <= Self.batchLimit else { throw AppError.validation(["At most \(Self.batchLimit) letters can be marked at once."]) }
    do {
      let envelope: APIEnvelope<BatchStatusDTO> = try await api.send("PUT", "messaging/status/batch", body: BatchStatusRequest(ids: ids, status: status.key))
      return envelope.data?.count ?? ids.count
    } catch AppError.notFound(let text) where text?.hasPrefix("Cannot ") == true {
      // An API from before PR #111 has no such address, and Express says "Cannot PUT /…". Say that, not
      // "not found", which would read as a missing letter ("Message 42 not found").
      throw AppError.server(status: 404, info: "This server cannot mark several letters at once yet. Mark them one at a time.")
    }
  }

  // MARK: - The group's numbers (API PR #112)

  /// Nil when the server does not count yet (an API from before PR #112).
  public func numbers() async throws -> GroupNumbers? {
    guard let groupId = viewer?.chapterId else { throw AppError.forbidden("This account is not a group admin of any group.") }
    let envelope: APIEnvelope<ChapterDTO> = try await api.get("chapter/chapter", query: [("id", String(groupId))])
    let dto = try envelope.required("group")
    // Staff-only fields: absent means the server is older than the counting, not that the count is zero.
    guard dto.lettersSentBefore != nil || dto.lettersCounted != nil else { return nil }
    let group = dto.toDomain()
    return GroupNumbers(groupName: group.name, before: dto.lettersSentBefore ?? 0, countedHere: dto.lettersCounted ?? 0, published: group.lettersSent, averageDaysToMail: group.averageDaysToMail)
  }

  public func setLettersSentBefore(_ count: Int) async throws {
    guard let groupId = viewer?.chapterId else { throw AppError.forbidden("This account is not a group admin of any group.") }
    guard count >= 0 else { throw AppError.validation(["The number cannot be negative."]) }
    // Only the id and the one field: `lettersSent` and `averageTimeDays` are the server's, and sending them changes nothing.
    try await api.send("PUT", "chapter/chapter", body: LettersSentBeforeRequest(id: groupId, lettersSentBefore: count))
  }

  /// Forward only: queued, printed, mailed. Anything else is a 409 whose sentence says why.
  ///
  /// `release`: the letter is held (the person was moved or freed after it was written) and is being
  /// printed all the same. Without it the API answers 409 `LetterHeldError`, so that printing a held
  /// letter is a decision and not an oversight (API PR #106).
  public func setStatus(messageId: Int, status: LetterStatus, release: Bool = false) async throws -> Letter {
    try await move(StatusRequest(id: messageId, status: status.key, release: release ? true : nil))
  }

  /// The post brought a mailed letter back (API PR #105). `note` is what the envelope said, 200 characters
  /// at most; the writer reads it and it is not encrypted in any mode, so nothing about the letter belongs in it.
  public func markReturned(messageId: Int, reason: ReturnReason, note: String?) async throws -> Letter {
    let words = note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard words.count <= Self.returnNoteLimit else { throw AppError.validation(["The note can be at most \(Self.returnNoteLimit) characters."]) }
    return try await move(StatusRequest(id: messageId, status: LetterStatus.returned.key, reason: reason.key, note: words.isEmpty ? nil : words))
  }

  public static let returnNoteLimit = 200

  private func move(_ request: StatusRequest) async throws -> Letter {
    await codec.ready()
    let envelope: APIEnvelope<MessageDTO> = try await api.send("PUT", "messaging/status", body: request)
    return codec.incoming(try envelope.required("letter"))
  }

  /// Queued letters of this group that are held, whatever the reason.
  ///
  /// An API from before PR #106 does not know `held` and answers with every letter the group relays. Only a
  /// letter that says it is held is one, so the page is checked here; against a current API that changes nothing.
  public func held(groupId: Int, page: Int, pageSize: Int) async throws -> Page<QueueItem> {
    let answer = try await queue(groupId: groupId, query: [("held", "true"), ("status", LetterStatus.queued.key)], page: page, pageSize: pageSize)
    let held = answer.items.filter(\.letter.isHeld)
    if held.count == answer.items.count { return answer }
    // The server did not filter, so its total and its further pages mean nothing either.
    return Page(items: held, total: held.count, page: answer.page, pageSize: answer.pageSize)
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
      let writer = try envelope.required("writer")
      // Server mode, before the switch: the writer gets a keypair all the same, if this member can make one.
      if case .ready(let group) = await keyring.load(anyMode: true) { _ = try? await giveKeys(to: writer.id, group: group) }
      return writer.toDomain()
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
    return try await giveKeys(to: writerId, group: group)
  }

  /// A keypair for an unclaimed writer who has none, private half sealed to the group. The API allows it once,
  /// and wants all three fields together: a public key whose private half nobody holds could never be opened.
  private func giveKeys(to writerId: Int, group: GroupKey) async throws -> Sodium.KeyPair {
    let made = try LetterCodec.sealing { try GroupKeys.createSealed(to: group.publicKey) }
    try await api.send("PUT", "auth/user", body: UpdateUserRequest(id: writerId, publicKey: made.publicKey, orgWrappedPrivateKey: made.sealedPrivateKey, orgKeyVersion: group.version))
    keyring.remember(writerId: writerId, keyPair: made.keyPair)
    return made.keyPair
  }

  public func revokeToken(writerId: Int) async throws {
    try await api.send("DELETE", "auth/writer/token", body: WriterRef(writer: writerId))
  }

  // MARK: - Key set-up after sign-in (API PR #95)

  /// What `setUpKeys` did and found. Everything is zero or empty for a writer's account.
  public struct KeySetUp: Equatable, Sendable {
    /// This phone made the group's keypair just now.
    public var madeGroupKey = false
    public var writersGivenKeys = 0
    /// Letters whose writer has keys by now and was given their envelope.
    public var lettersShared = 0
    /// Members with keys of their own who do not hold the group key. Handing it over is the one step
    /// that waits for a person: see `docs/DECISIONS.md`.
    public var membersWaiting: [GroupMember] = []
  }

  /// A group member's share of the move to end-to-end encryption, done without being asked after every
  /// sign-in and launch, in either mode (the key endpoints work before the switch, and that is the point:
  /// the switch waits only for every relaying group to have its key). Best effort throughout; whatever
  /// fails is tried again next time.
  ///
  /// 2. The group has no key: make one. 4. Unclaimed writers with no keys: make them, sealed to the group.
  /// 5. End-to-end only: letters the group can open whose writer has keys by now and no envelope: seal
  /// the content key to them. (1 is the member's own keys, made at sign-in by `SessionRepository`;
  /// 3, handing the group key to members who lack it, is reported here and done by a person.)
  public func setUpKeys() async -> KeySetUp {
    var done = KeySetUp()
    guard let me = viewer, me.role == Role.chapter, me.chapterId != nil else { return done }
    var state = await keyring.load(force: true, anyMode: true)
    if case .notSetUp = state, (try? await setUpGroupKey()) != nil {
      state = keyring.state
      done.madeGroupKey = state.isReady
    }
    guard case .ready(let group) = state else { return done }

    // 4. The group's shared anonymous account is not a person and never has keys.
    for writer in (try? await writerRows()) ?? [] where writer.publicKey == nil && writer.anonymousForChapter == nil {
      if (try? await giveKeys(to: writer.id, group: group)) != nil { done.writersGivenKeys += 1 }
    }

    // 5.
    if await codec.isEndToEnd(), let waiting = (try? await api.get("messaging/envelopes/missing") as APIEnvelope<[MissingEnvelopeDTO]>)?.data {
      for w in waiting {
        guard let theirKey = w.publicKey, let sealedToGroup = w.wrappedKey,
              let contentKey = try? LetterCipher.openEnvelope(sealedToGroup, keyPair: group.keyPair),
              let sealed = try? LetterCipher.seal(contentKey: contentKey, to: Reader(type: w.readerType ?? Reader.user, id: w.readerId, publicKey: theirKey))
        else { continue }
        let request = AddEnvelopeRequest(message: w.message, readerType: sealed.readerType, readerId: sealed.readerId, wrappedKey: sealed.wrappedKey, keyVersion: nil)
        if (try? await api.send("POST", "messaging/envelope", body: request)) != nil { done.lettersShared += 1 }
      }
    }

    // 3. Only the group-owner admin can hand the key (API PR #115); anyone else is shown nothing to do.
    if let roster = try? await roster(), roster.iAmOwner {
      done.membersWaiting = roster.members.filter { $0.hasOwnKey && !$0.holdsGroupKey && !$0.isMe }
    }
    return done
  }

  // MARK: - The group's own key

  /// Where this member stands with the group key. Always `notNeeded` in server mode.
  public var keyState: GroupKeyState { keyring.state }

  @discardableResult
  public func refreshKeyState() async -> GroupKeyState { await keyring.load(force: true, anyMode: true) }

  /// Makes the group's keypair on this device, once, and seals the private half to this member.
  public func setUpGroupKey() async throws {
    guard let user = viewer else { throw AppError.unauthorized("You are signed out.") }
    guard let groupId = user.chapterId else { throw AppError.forbidden("This account is not a group admin of any group.") }
    guard let mine = vault.keyPair(for: user.id) else { throw AppError.lettersLocked }
    let made = try LetterCodec.sealing { try GroupKeys.createSealed(to: Sodium.toBase64(mine.publicKey)) }
    defer { made.keyPair.wipe() }
    // Success or not, ask again: on a 409 another member set the key up first, and the state should say so.
    do {
      try await api.send("PUT", "auth/chapter-keys", body: GroupKeyRequest(chapter: groupId, publicKey: made.publicKey, wrappedOrgPrivateKey: made.sealedPrivateKey))
    } catch {
      await keyring.load(force: true, anyMode: true)
      throw error
    }
    await keyring.load(force: true, anyMode: true)
  }

  private func memberRows(groupId: Int) async throws -> [MemberDTO] {
    let envelope: APIEnvelope<MemberKeysDTO> = try await api.get("auth/member-keys", query: [("chapter", String(groupId))])
    return envelope.data?.members ?? []
  }

  /// The group's admins and whether each holds the group key.
  public func members() async throws -> [GroupMember] { try await roster().members }

  /// The group's admins, who owns the key, and whether this account does (API PR #115).
  public func roster() async throws -> GroupRoster {
    guard let user = viewer else { throw AppError.unauthorized("You are signed out.") }
    guard let groupId = user.chapterId else { return GroupRoster(members: [], ownerId: nil, iAmOwner: false) }
    let envelope: APIEnvelope<MemberKeysDTO> = try await api.get("auth/member-keys", query: [("chapter", String(groupId))])
    let waiting = Set(envelope.data?.waiting ?? [])
    let owner = envelope.data?.owner
    let members = (envelope.data?.members ?? []).map {
      GroupMember(id: $0.id, name: $0.name?.nonBlank ?? $0.username ?? "Group admin \($0.id)", hasOwnKey: $0.publicKey != nil, holdsGroupKey: $0.holdsGroupKey ?? false, isMe: $0.id == user.id, isOwner: $0.id == owner, isWaiting: waiting.contains($0.id))
    }
    // An API from before the roles names no owner; there, any holder may hand the key, as before.
    let iAmOwner = owner.map { $0 == user.id } ?? (members.first { $0.isMe }?.holdsGroupKey ?? false)
    return GroupRoster(members: members, ownerId: owner, iAmOwner: iAmOwner)
  }

  public static let handKeyFirst = AppError.validation(["Hand them the group key first. An owner who does not hold the key could hand it to nobody, not even themselves, and only a superadmin could undo that."])

  /// Makes another group admin the chapter's group-owner admin; this account stops being it (API PR #115).
  /// Only for a group admin who already holds the key: see `docs/DECISIONS.md`.
  public func makeOwner(_ member: GroupMember) async throws {
    guard let groupId = viewer?.chapterId else { throw AppError.forbidden("This account is not a group admin of any group.") }
    guard member.holdsGroupKey else { throw Self.handKeyFirst }
    let _: APIEnvelope<OwnerDTO> = try await api.send("PUT", "auth/chapter-owner", body: OwnerRequest(chapter: groupId, user: member.id))
    await keyring.load(force: true, anyMode: true) // the loaded key says whether this account owns it
  }

  /// A key holder hands the group key to another member, sealed to that member's public key.
  public func handKey(to memberId: Int) async throws {
    let group = try await groupKey()
    // Their public key comes from the members list, which only this group and admins can read.
    guard let theirKey = try await memberRows(groupId: group.groupId).first(where: { $0.id == memberId })?.publicKey else {
      throw AppError.validation(["That group admin has no key of their own yet. They get one the first time they sign in; hand them the group key after that."])
    }
    let sealed = try LetterCodec.sealing { try GroupKeys.sealPrivateKey(group.keyPair.privateKey, to: theirKey) }
    do {
      try await api.send("PUT", "auth/member-key", body: MemberKeyRequest(chapter: group.groupId, user: memberId, wrappedOrgPrivateKey: sealed, keyVersion: group.version))
    } catch let e as AppError where e.isKeyRotated {
      // The group rotated its key while this phone was sealing the old one. Forget the old one now; the next try uses the new.
      await keyring.load(force: true, anyMode: true)
      throw AppError.conflict("Your group changed its key a moment ago. The new one has been fetched; try again.", name: "KeyVersionError")
    }
  }

  /// Stops handing the key out. It cannot take back a key already opened; that needs a rotation.
  public func stopHandingKey(to memberId: Int) async throws {
    guard let groupId = viewer?.chapterId else { throw AppError.forbidden("This account is not a group admin of any group.") }
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
