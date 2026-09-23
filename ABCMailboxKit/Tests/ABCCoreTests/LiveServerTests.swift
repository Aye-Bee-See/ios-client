@testable import ABCCore
import XCTest

/// The whole core layer against a running API, read-only: it signs in and reads, and never sends,
/// edits, or changes status, so it is safe to point at a development database others are using.
///
///     ABC_LIVE_SERVER=http://localhost:3000 ABC_LIVE_E2E=http://localhost:3100 swift test --filter LiveServer
///
/// Needs the development data from Android's `tools/dev-seed.py` (user1, member1). Skipped unless
/// the variables are set. The end-to-end half is the one that matters most: it opens, with this
/// package's crypto, letters that the Android app and the server's tooling wrote.
@MainActor
final class LiveServerTests: XCTestCase {
  private func env(_ name: String) -> String? { ProcessInfo.processInfo.environment[name].flatMap { $0.isEmpty ? nil : $0 } }

  private func container(_ variable: String) throws -> AppContainer {
    guard let base = env(variable), let normalised = DevServerRepository.normalise(base), let url = URL(string: normalised) else { throw XCTSkip("set \(variable) to a running API") }
    let suite = "abc-live-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
    return AppContainer(defaultBaseURL: url, secrets: InMemorySecretStore(), defaults: defaults, files: LocalFiles(root: scratch), draftsDirectory: scratch.appendingPathComponent("drafts"), offlineDirectory: scratch.appendingPathComponent("offline"), outboxDirectory: scratch.appendingPathComponent("outbox"))
  }

  func testServerModeThePublicDirectoryAndTheOfflineCopy() async throws {
    let app = try container("ABC_LIVE_SERVER")
    let mode = await app.modes.refresh()
    XCTAssertEqual(mode, .server)

    // The public directory, signed out.
    let page = try await app.directory.prisoners(PrisonerFilter(), page: 1, pageSize: 5)
    XCTAssertEqual(page.items.count, 5); XCTAssertGreaterThan(page.total, 5)
    let first = try XCTUnwrap(page.items.first)
    XCTAssertNotNil(first.facility, "list rows carry the facility summary (API PR #79)")
    let prisoner = try await app.directory.prisoner(id: first.id)
    XCTAssertEqual(prisoner.name, first.name)
    let facility = try await app.directory.facility(id: try XCTUnwrap(prisoner.facilityId))
    print("live: \(prisoner.name) at \(facility.name): \(facility.rules.lines())")
    let groups = try await app.directory.groups(GroupFilter(), page: 1, pageSize: 5)
    XCTAssertFalse(groups.items.isEmpty)
    XCTAssertEqual(app.directory.source, .live)

    try await app.offline.download()
    print("live: offline copy holds \(app.offline.counts)")
    XCTAssertEqual(app.offline.counts.prisoners, page.total, "signed out, the copy and the public list agree")

  }

  func testServerModeAWriterAndAGroupMember() async throws {
    let app = try container("ABC_LIVE_SERVER")
    await app.modes.refresh()
    let writerPassword = env("ABC_LIVE_WRITER_PASSWORD") ?? "password1"
    try await skipUnlessKeysExist("user1", writerPassword, on: "ABC_LIVE_SERVER")
    try await skipUnlessKeysExist("member1", "password1", on: "ABC_LIVE_SERVER")

    // A writer.
    try await app.sessions.login(username: "user1", password: writerPassword)
    XCTAssertFalse(app.sessions.keysLocked)
    let threads = try await app.letters.threads(page: 1, pageSize: 20)
    let thread = try await app.letters.thread(chatId: try XCTUnwrap(threads.items.first?.id, "user1 has a thread on a seeded database"))
    XCTAssertFalse(thread.letters.isEmpty)
    XCTAssertFalse(try XCTUnwrap(thread.letters.first).body.isEmpty)
    _ = try await app.letters.retentionDays()
    try await app.sessions.logout()

    // A group member.
    let member = try await app.sessions.login(username: "member1", password: "password1")
    let groupId = try XCTUnwrap(member.user.staffGroupId)
    for status in [LetterStatus.queued, .printed, .mailed] {
      let queue = try await app.group.queue(groupId: groupId, status: status, page: 1, pageSize: 20)
      print("live: \(queue.total) \(status.key) in group \(groupId)'s queue")
      if let item = queue.items.first { XCTAssertNotNil(item.prisoner, "queue rows are given their prisoner for addressing") }
    }
    let writers = try await app.group.writers()
    print("live: group \(groupId) manages \(writers.map(\.name))")
    try await app.sessions.logout()
    XCTAssertFalse(app.sessions.state.isSignedIn)
  }

  /// Signing in to an account with no keys creates them (API PR #95), which is a write; look before leaping.
  /// A server-mode sign-in answer carries no key bundle, so there the bundle is asked for with the token.
  private func skipUnlessKeysExist(_ username: String, _ password: String, on variable: String = "ABC_LIVE_E2E") async throws {
    let base = URL(string: DevServerRepository.normalise(try XCTUnwrap(env(variable)))!)!
    let cache = SessionCache()
    let peek = APIClient(baseURL: DevServerURL(defaultURL: base), cache: cache)
    let login: APIEnvelope<LoginData>
    do { login = try await peek.send("POST", "auth/login", body: LoginRequest(username: username, password: password)) } catch {
      throw XCTSkip("cannot sign in to \(base) as \(username) (\(AppError.from(error).readable)). One attempt only: wrong sign-ins lock the account.")
    }
    var bundle = login.data?.keys
    if bundle == nil {
      cache.token = login.data?.token.token
      bundle = (try? await peek.get("auth/keys") as APIEnvelope<KeyBundleDTO>)?.data
      try? await peek.send("POST", "auth/logout", body: LogoutRequest(everywhere: false))
    }
    guard bundle?.material != nil else { throw XCTSkip("\(username) has no keys on \(base) yet; signing in with this app would create them, and this test only reads") }
  }

  /// Set ABC_LIVE_WRITER_PASSWORD if a recovery test changed user1's password on the e2e server.
  func testEndToEndModeAWritersLettersWrittenByOtherClientsOpenHere() async throws {
    let app = try container("ABC_LIVE_E2E")
    let mode = await app.modes.refresh()
    XCTAssertEqual(mode, .e2e)
    let password = env("ABC_LIVE_WRITER_PASSWORD") ?? "password1"
    try await skipUnlessKeysExist("user1", password)

    try await app.sessions.login(username: "user1", password: password)
    XCTAssertFalse(app.sessions.keysLocked, "the password opened the key another client wrapped")
    XCTAssertNil(app.sessions.pendingRecoveryCode, "no new keys were made")
    var opened = 0, locked = 0
    for summary in try await app.letters.threads(page: 1, pageSize: 20).items {
      for letter in try await app.letters.thread(chatId: summary.id).letters { if letter.locked { locked += 1 } else if !letter.body.isEmpty { opened += 1 } }
    }
    print("live e2e: user1 opened \(opened) letters, \(locked) locked")
    XCTAssertGreaterThan(opened, 0, "at least one letter written by another client decrypted here")
    try await app.sessions.logout()
  }

  /// A group member: own key -> group key -> letters sealed to the group, and writers' keys in custody.
  func testEndToEndModeAGroupMemberReadsThroughTheGroupKeyAnotherClientMade() async throws {
    let app = try container("ABC_LIVE_E2E")
    let mode = await app.modes.refresh()
    XCTAssertEqual(mode, .e2e)
    try await skipUnlessKeysExist("member1", "password1")

    try await app.sessions.login(username: "member1", password: "password1")
    XCTAssertFalse(app.sessions.keysLocked, "the password opened the key another client wrapped")
    let state = await app.keyring.load()
    guard case .ready(let key) = state else { throw XCTSkip("member1 does not hold the group key on this server: \(state)") }
    print("live e2e: member1 opened group \(key.groupId)'s key, version \(key.version)")

    var readable = 0, locked = 0
    for summary in try await app.letters.threads(page: 1, pageSize: 20).items {
      for letter in try await app.letters.thread(chatId: summary.id).letters { if letter.locked { locked += 1 } else if !letter.body.isEmpty { readable += 1 } }
    }
    let queue = try await app.group.queue(groupId: key.groupId, status: .queued, page: 1, pageSize: 20)
    print("live e2e: member1 read \(readable) letters (\(locked) locked); \(queue.items.filter { !$0.letter.locked }.count) of \(queue.total) queued letters readable")
    XCTAssertGreaterThan(readable, 0, "letters sealed to the group by other clients decrypted here")
    // The notification feed: fetched, never marked read (that would be a write).
    let fresh = await app.activity.sync()
    print("live e2e: member1's feed has \(app.activity.unread) unread; newest: \(fresh.prefix(3).map(\.sentence))")
    XCTAssertEqual(fresh.count <= app.activity.unread, true)
    let members = try await app.group.members()
    print("live e2e: members \(members.map { "\($0.name)\($0.holdsGroupKey ? " (holds key)" : "")" })")
    try await app.sessions.logout()
    XCTAssertFalse(app.keyring.state.isReady, "signing out forgets the group key")
  }

  // MARK: - Destructive. Only ever against a server made to be thrown away.

  /// Deletes a seeded account on a real API (PR #104), wrong password first. **This one writes and deletes**,
  /// unlike everything above, so it has a variable of its own and refuses the usual development ports:
  ///
  ///     # a throwaway API: its own database file, DB_RESET=true DB_SEED=true, some unused port
  ///     ABC_LIVE_THROWAWAY=http://localhost:3199 swift test --filter testThrowawayServer
  ///
  /// It uses the seed's `user3` / `password3`, so nothing has to be created, and it cannot be run twice
  /// against the same database: the second time, user3 is gone.
  func testThrowawayServerDeletingAnAccountWrongPasswordFirst() async throws {
    let app = try container("ABC_LIVE_THROWAWAY")
    let base = try XCTUnwrap(env("ABC_LIVE_THROWAWAY"))
    for port in [":3000", ":3100"] { XCTAssertFalse(base.contains(port), "that is a development server people use; this test deletes") }
    await app.modes.refresh()

    try await app.sessions.login(username: "user3", password: "password3")
    app.sessions.recoveryCodeSaved()
    let firstPage = try await app.directory.prisoners(PrisonerFilter(), page: 1, pageSize: 1)
    let prisoner = try XCTUnwrap(firstPage.items.first)
    let sent = try await app.letters.send(NewLetter(prisonerId: prisoner.id, body: "A letter that is about to be deleted with its account.", relayNote: nil, relayChapter: nil))
    app.drafts.save(userId: try XCTUnwrap(app.sessions.state.user?.id), prisonerId: prisoner.id, draft: Draft(body: "and a draft", note: nil, relayChapter: nil))

    let preview = await app.accountDeletion.preview()
    print("live throwaway: before deleting, user3 has \(preview.conversations ?? -1) conversations")
    XCTAssertGreaterThanOrEqual(try XCTUnwrap(preview.conversations), 1)

    // 1. The server's own check (PR #104), asked directly, without the phone's check in front of it.
    await assertThrowsAppError(try await app.sessions.deleteAccount(password: "not the password")) {
      print("live throwaway: the server answered a wrong password with: \($0)")
      guard case .forbidden = $0 else { return XCTFail("expected the server's 403, got \($0)") }
    }
    XCTAssertTrue(app.sessions.state.isSignedIn, "a 403 is not a revoked session")

    // 2. The way the app does it: the phone proves the password first.
    await assertThrowsAppError(try await app.accountDeletion.deleteMyAccount(password: "not the password")) { XCTAssertEqual($0, AccountDeletion.wrongPassword) }
    XCTAssertTrue(app.sessions.state.isSignedIn)
    let stillThere = try await app.letters.letter(messageId: sent.id)
    XCTAssertEqual(stillThere.body, "A letter that is about to be deleted with its account.", "nothing was deleted")

    // 3. The right password.
    let gone = try await app.accountDeletion.deleteMyAccount(password: "password3")
    print("live throwaway: deleted \(gone)")
    XCTAssertGreaterThanOrEqual(gone.letters, 1); XCTAssertGreaterThanOrEqual(gone.threads, 1)
    XCTAssertFalse(app.sessions.state.isSignedIn)
    XCTAssertNil(app.drafts.load(userId: 3, prisonerId: prisoner.id))
    await assertThrowsAppError(try await app.sessions.login(username: "user3", password: "password3")) { XCTAssertTrue($0.isUnauthorized, "the account is gone: \($0)") }
  }

  // MARK: Returned mail, moved and freed (API PRs #105 and #106)

  /// What a network admin does in the dashboard, which this app has no screens for: the test needs someone
  /// to move and free a prisoner. Plain requests, so that nothing of the app is involved in the set-up.
  private struct Admin {
    let base: URL
    let token: String

    static func signIn(_ base: String) async throws -> Admin {
      let url = try XCTUnwrap(URL(string: base.hasSuffix("/") ? base : base + "/"))
      let answer = try await call(url, "POST", "auth/login", ["username": "admin", "password": "abcpassword"], token: nil)
      let token = try XCTUnwrap(((answer["data"] as? [String: Any])?["token"] as? [String: Any])?["token"] as? String, "the throwaway server needs ADMIN_PASSWORD=abcpassword, as tools/dev-seed.py expects")
      return Admin(base: url, token: token)
    }

    @discardableResult func put(_ path: String, _ body: [String: Any]) async throws -> [String: Any] { try await Self.call(base, "PUT", path, body, token: token) }

    private static func call(_ base: URL, _ method: String, _ path: String, _ body: [String: Any], token: String?) async throws -> [String: Any] {
      var request = URLRequest(url: base.appendingPathComponent(path))
      request.httpMethod = method
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
      let (data, response) = try await URLSession.shared.data(for: request)
      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
      let status = (response as? HTTPURLResponse)?.statusCode ?? 0
      if !(200..<300).contains(status) { throw AppError.unexpected("admin \(method) \(path) -> \(status): \(json)") }
      return json
    }
  }

  /// The three stories of API PRs #105 and #106, against a real API, from the writer's phone and the group
  /// member's. It moves letters through their lifecycle and edits the directory, so like the test above it
  /// only runs against a throwaway server and refuses the usual development ports:
  ///
  ///     # a throwaway API at PR #106 or later, seeded, with ADMIN_PASSWORD=abcpassword, then:
  ///     python3 ../../Android/tools/dev-seed.py http://localhost:3199   # member1, relay links
  ///     ABC_LIVE_THROWAWAY=http://localhost:3199 swift test --filter testThrowawayServerReturnedMovedAndFreed
  ///
  /// Server mode. In end-to-end mode a move holds letters as `reseal_needed` instead of `choose_relay`.
  func testThrowawayServerReturnedMovedAndFreed() async throws {
    let writer = try container("ABC_LIVE_THROWAWAY"), member = try container("ABC_LIVE_THROWAWAY")
    let base = try XCTUnwrap(env("ABC_LIVE_THROWAWAY"))
    for port in [":3000", ":3100"] { XCTAssertFalse(base.contains(port), "that is a development server people use; this test edits its directory") }
    await writer.modes.refresh(); await member.modes.refresh()
    try XCTSkipIf(writer.modes.mode == .e2e, "written for server mode")
    let admin = try await Admin.signIn(base)
    try await writer.sessions.login(username: "user1", password: "password1")
    try await member.sessions.login(username: "member1", password: "password1")
    let groupId = try XCTUnwrap(member.sessions.state.user?.chapterId)
    await writer.activity.sync() // whatever the seed left in the feed is not this test's news

    // 1. Returned. dev-seed: prison 1 has one relay group, member1's, so the server picks it.
    let first = try await writer.letters.send(NewLetter(prisonerId: 1, body: "The tomatoes are in.", relayNote: nil, relayChapter: nil))
    XCTAssertEqual(first.relayGroupId, groupId)
    _ = try await member.group.setStatus(messageId: first.id, status: .printed)
    _ = try await member.group.setStatus(messageId: first.id, status: .mailed)
    await assertThrowsAppError(try await writer.letters.send(NewLetter(prisonerId: 1, body: "Too early", relayNote: nil, relayChapter: nil, resendOf: first.id))) {
      print("live #105: sending a mailed letter again is refused with: \($0)")
      guard case .validation = $0 else { return XCTFail("expected a 400, got \($0)") }
    }
    let back = try await member.group.markReturned(messageId: first.id, reason: .transferred, note: "Stamped NOT HERE")
    XCTAssertEqual(back.status, .returned); XCTAssertEqual(back.returnReason, .transferred); XCTAssertEqual(back.returnNote, "Stamped NOT HERE")
    let returnedList = try await member.group.queue(groupId: groupId, status: .returned, page: 1, pageSize: 50)
    XCTAssertTrue(returnedList.items.contains { $0.id == first.id })

    var news = await writer.activity.sync()
    print("live #105: the writer's feed says: \(news.map(\.sentence))")
    XCTAssertEqual(news.first?.kind, .returned); XCTAssertEqual(news.first?.messageId, first.id)
    let cameBack = try await writer.letters.letter(messageId: first.id)
    XCTAssertEqual(cameBack.returnReason, .transferred); XCTAssertEqual(cameBack.returnNote, "Stamped NOT HERE"); XCTAssertTrue(cameBack.canSendAgain); XCTAssertFalse(cameBack.canEdit)
    let again = try await writer.letters.send(NewLetter(prisonerId: 1, body: cameBack.body, relayNote: nil, relayChapter: nil, resendOf: first.id))
    XCTAssertEqual(again.resendOf, first.id); XCTAssertEqual(again.status, .queued)
    let replaced = try await writer.letters.letter(messageId: first.id)
    XCTAssertEqual(replaced.resentAs.map(\.id), [again.id]); XCTAssertFalse(replaced.canSendAgain)
    let thread = try await writer.letters.thread(chatId: try XCTUnwrap(again.threadId))
    let inThread = try XCTUnwrap(thread.letters.first { $0.id == first.id })
    XCTAssertEqual(inThread.returnReason, .transferred, "a thread's letters carry the reason")
    XCTAssertEqual(inThread.returnNote, "Stamped NOT HERE", "and the note, which the conversation does not send and the phone fetches")
    XCTAssertEqual(inThread.resentAs.map(\.id), [again.id]); XCTAssertFalse(inThread.canSendAgain, "sent again once: the conversation must not offer it twice")

    // 2. Freed. The letter just sent again is queued for member1's group; the directory learns they are out.
    try await admin.put("prisoner/prisoner", ["id": 1, "status": "free"])
    news = await writer.activity.sync()
    print("live #106: after the release the writer's feed says: \(news.map(\.sentence))")
    guard case .freed(let waitingCount)? = news.first?.kind, waitingCount >= 1 else { return XCTFail("expected prisoner.status free with a letter waiting, got \(String(describing: news.first?.kind))") }
    let waiting = try await writer.letters.letter(messageId: again.id)
    XCTAssertEqual(waiting.heldReason, .prisonerFree); XCTAssertTrue(waiting.isHeld); XCTAssertTrue(waiting.canEdit)
    let held = try await member.group.held(groupId: groupId, page: 1, pageSize: 50)
    XCTAssertTrue(held.items.contains { $0.id == again.id })
    await assertThrowsAppError(try await member.group.setStatus(messageId: again.id, status: .printed)) {
      print("live #106: printing a held letter without saying so is refused with: \($0)")
      XCTAssertTrue($0.isLetterHeld)
    }
    let printed = try await member.group.setStatus(messageId: again.id, status: .printed, release: true)
    XCTAssertEqual(printed.status, .printed); XCTAssertNil(printed.heldReason)

    // 3. Moved. Prison 4 has no relay group, so a letter there has none. Prison 3 only takes relayed mail;
    // with a second group attached there is nothing the server can decide for the writer.
    try await admin.put("prison/relay", ["prison": 3, "chapter": groupId])
    let direct = try await writer.letters.send(NewLetter(prisonerId: 4, body: "Written before the move.", relayNote: "two pages", relayChapter: nil))
    XCTAssertNil(direct.relayGroupId)
    let moved = try await admin.put("prisoner/prisoner", ["id": 4, "prison": 3])
    print("live #106: the directory edit reports: \((moved["data"] as? [String: Any])?["mail"] ?? moved["mail"] ?? "nothing under mail")")
    news = await writer.activity.sync()
    print("live #106: after the move the writer's feed says: \(news.map(\.sentence))")
    // At least this letter: the seed is random and may have left the writer another queued letter to the same person.
    guard case .moved(let held)? = news.first?.kind, held >= 1 else { return XCTFail("expected prisoner.moved with a letter waiting, got \(String(describing: news.first?.kind))") }
    let stuck = try await writer.letters.letter(messageId: direct.id)
    XCTAssertEqual(stuck.heldReason, .chooseRelay)

    // What the conversation screen does: ask the directory where they are now, and offer those groups.
    let now = try await writer.directory.prisoner(id: 4)
    let facility = try await writer.directory.facility(id: try XCTUnwrap(now.facilityId))
    let options = facility.relayGroups.filter(\.isActive)
    print("live #106: \(facility.name) is mailed to by \(options.map(\.name))")
    XCTAssertGreaterThanOrEqual(options.count, 2); XCTAssertTrue(options.contains { $0.id == groupId })
    try await writer.letters.chooseRelay(messageId: direct.id, groupId: groupId)
    let chosen = try await writer.letters.letter(messageId: direct.id)
    XCTAssertNil(chosen.heldReason); XCTAssertEqual(chosen.relayGroupId, groupId); XCTAssertEqual(chosen.body, "Written before the move."); XCTAssertEqual(chosen.relayNote, "two pages")
    let queue = try await member.group.queue(groupId: groupId, status: .queued, page: 1, pageSize: 50)
    XCTAssertTrue(queue.items.contains { $0.id == direct.id }, "the group the writer chose now has it to print")
    _ = try await member.group.setStatus(messageId: direct.id, status: .printed) // no longer held: no release needed
  }

  /// Letter nights and a group's numbers (API PRs #111 and #112), against a real API. It moves letters and edits
  /// the group, so it only runs against a throwaway server, set up as for the test above:
  ///
  ///     ABC_LIVE_THROWAWAY=http://localhost:3199 swift test --filter testThrowawayServerLetterNightsAndNumbers
  func testThrowawayServerLetterNightsAndNumbers() async throws {
    let writer = try container("ABC_LIVE_THROWAWAY"), member = try container("ABC_LIVE_THROWAWAY")
    let base = try XCTUnwrap(env("ABC_LIVE_THROWAWAY"))
    for port in [":3000", ":3100", ":3069"] { XCTAssertFalse(base.contains(port), "that is a development server people use; this test moves letters") }
    await writer.modes.refresh(); await member.modes.refresh()
    try await writer.sessions.login(username: "user1", password: "password1")
    try await member.sessions.login(username: "member1", password: "password1")
    let groupId = try XCTUnwrap(member.sessions.state.user?.chapterId)
    await writer.activity.sync()

    // Three letters to someone whose facility this group mails to (dev-seed: prison 1).
    var ids: [Int] = []
    for i in 1...3 { ids.append(try await writer.letters.send(NewLetter(prisonerId: 1, body: "Letter night \(i)", relayNote: nil, relayChapter: nil)).id) }

    // 3.1 One request: every row brings the prisoner, the facility and its address.
    let queue = try await member.group.queue(groupId: groupId, status: .queued, page: 1, pageSize: 100)
    let mine = queue.items.filter { ids.contains($0.id) }
    XCTAssertEqual(mine.count, 3)
    for row in mine {
      XCTAssertNotNil(row.prisoner?.facility, "prisoner_details with prison_details on every row")
      XCTAssertFalse(row.prisoner?.facility?.addressLines.isEmpty ?? true, "the address is what the envelope needs")
    }
    print("live #111: a queue row is addressed to \(mine.first?.prisoner?.birthName ?? mine.first?.prisoner?.name ?? "?"), \(mine.first?.prisoner?.facility?.name ?? "?"), \(mine.first?.prisoner?.facility?.addressLines ?? [])")

    // 3.2 All or none. One of the three is printed by itself first, so the three together must be refused.
    _ = try await member.group.setStatus(messageId: ids[1], status: .printed)
    await assertThrowsAppError(try await member.group.setStatusOfMany(messageIds: ids, status: .printed)) {
      print("live #111: the refusal reads: \($0.userMessage ?? "nil")")
      XCTAssertTrue($0.isConflict); XCTAssertTrue($0.userMessage?.contains("\(ids[1])") == true, "it names the letter")
    }
    let untouched = try await member.group.queueItem(messageId: ids[0])
    XCTAssertEqual(untouched.letter.status, .queued, "nothing moved")
    await writer.activity.sync()

    let moved = try await member.group.setStatusOfMany(messageIds: [ids[0], ids[2]], status: .printed)
    XCTAssertEqual(moved, 2)
    // 1.2 The writer is told once, with how many.
    let news = await writer.activity.sync()
    print("live #111: the writer's feed says: \(news.map(\.sentence))")
    XCTAssertEqual(news.count, 1); XCTAssertEqual(news.first?.kind, .printed); XCTAssertEqual(news.first?.count, 2); XCTAssertNil(news.first?.messageId)

    // 3.4 A group's numbers. Mailing the three counts them; twenty-five from before puts the group over twenty.
    let before = try await member.group.numbers()
    let start = try XCTUnwrap(before, "this server counts")
    XCTAssertNil(start.published, "nothing, not 0, for a group under twenty")
    let mailed = try await member.group.setStatusOfMany(messageIds: ids, status: .mailed)
    XCTAssertEqual(mailed, 3)
    try await member.group.setLettersSentBefore(25)
    let after = try await member.group.numbers()
    let numbers = try XCTUnwrap(after)
    print("live #112: the group's numbers: \(numbers)")
    XCTAssertEqual(numbers.before, 25); XCTAssertEqual(numbers.countedHere, start.countedHere + 3); XCTAssertEqual(numbers.published, String(numbers.total))
    let page = try await writer.directory.group(id: groupId)
    XCTAssertEqual(page.lettersSent, numbers.published, "what the public page shows is what the server publishes")
  }

  /// Claim tokens carry the server's date (API PR #113: two weeks by default, and the operator's to change).
  /// It issues a token, which replaces any the writer had, so it is for a throwaway server like the tests above.
  func testThrowawayServerAClaimTokenSaysHowLongItIsGoodFor() async throws {
    let member = try container("ABC_LIVE_THROWAWAY"), newcomer = try container("ABC_LIVE_THROWAWAY")
    let base = try XCTUnwrap(env("ABC_LIVE_THROWAWAY"))
    for port in [":3000", ":3100", ":3069"] { XCTAssertFalse(base.contains(port), "that is a development server people use; this test replaces a writer's claim token") }
    await member.modes.refresh(); await newcomer.modes.refresh()
    try await member.sessions.login(username: "member1", password: "password1")
    let writers = try await member.group.writers()
    let writer = try XCTUnwrap(writers.first, "dev-seed adds a managed writer")

    let issued = try await member.group.issueToken(writerId: writer.id)
    let until = try XCTUnwrap(issued.expiresAt, "the volunteer's screen says this date")
    let days = until.timeIntervalSinceNow / 86_400
    print("live #113: the token is good until \(until), \(String(format: "%.1f", days)) days from now")
    XCTAssertGreaterThan(days, 3.5, "longer than the 72 hours it used to be")

    // The newcomer's screen asks without being signed in, and is told the same date.
    let info = try await newcomer.sessions.claimInfo(token: issued.token)
    XCTAssertEqual(try XCTUnwrap(info.expiresAt).timeIntervalSince1970, until.timeIntervalSince1970, accuracy: 1)
    let listed = try await member.group.writers()
    XCTAssertEqual(try XCTUnwrap(listed.first { $0.id == writer.id }?.tokenExpiresAt).timeIntervalSince1970, until.timeIntervalSince1970, accuracy: 1)
  }

  /// What the server says an account's scheme is, asked as the app asks, without a token.
  private func scheme(_ base: String, _ username: String) async throws -> String? {
    var comps = try XCTUnwrap(URLComponents(string: base.hasSuffix("/") ? base + "auth/login-params" : base + "/auth/login-params"))
    comps.queryItems = [URLQueryItem(name: "username", value: username)]
    let (data, _) = try await URLSession.shared.data(from: try XCTUnwrap(comps.url))
    return ((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["data"] as? [String: Any])?["scheme"] as? String
  }

  /// The split sign-in scheme (API PR #114) on an end-to-end server with REQUIRE_SPLIT_AUTH on: what production
  /// will be from the first push. An account from before (member1, made by an admin before the flag) signs in by
  /// the fallback and moves to split at its password change; a newcomer claims split and everything after that
  /// is one derivation per sign-in. The password is checked against every request's shape only in the unit
  /// tests (the recorder); here the proof is that a real API accepts what the phone sends, and that letters
  /// sealed under keys wrapped this way open on both sides.
  ///
  ///     # an end-to-end throwaway API: ENCRYPTION_MODE=e2e, seeded, dev-seed.py run, then restarted with REQUIRE_SPLIT_AUTH=true
  ///     ABC_LIVE_THROWAWAY=http://localhost:3199 swift test --filter testThrowawayServerEndToEndSplitAuth
  func testThrowawayServerEndToEndSplitAuth() async throws {
    let member = try container("ABC_LIVE_THROWAWAY"), newcomer = try container("ABC_LIVE_THROWAWAY")
    let base = try XCTUnwrap(env("ABC_LIVE_THROWAWAY"))
    for port in [":3000", ":3100", ":3069"] { XCTAssertFalse(base.contains(port), "that is a development server people use; this test changes passwords and deletes an account") }
    await member.modes.refresh(); await newcomer.modes.refresh()
    try XCTSkipIf(member.modes.mode != .e2e, "written for an end-to-end server")
    let memberScheme = try await scheme(base, "member1")
    XCTAssertEqual(memberScheme, "split", "under the flag the handshake calls every name split")

    // 1. An account from before: the auth key is refused, the password follows once, keys are made at that sign-in.
    try await member.sessions.login(username: "member1", password: "password1")
    XCTAssertFalse(member.schemes.isKnownSplit("member1"), "a fallback sign-in is not a split one")
    let memberKey = try Data(XCTUnwrap(member.vault.keyPair(for: try XCTUnwrap(member.sessions.state.user?.id))).privateKey)
    member.sessions.recoveryCodeSaved()
    let setUp = await member.group.setUpKeys()
    print("live #114: member1 signed in by the fallback; group key made: \(setUp.madeGroupKey), writers given keys: \(setUp.writersGivenKeys)")
    XCTAssertTrue(member.group.keyState.isReady)

    // 2. The password change moves it to split: from here one derivation, and the same key.
    try await member.sessions.changePassword(current: "password1", new: "Bicycle tomato harvest 9")
    XCTAssertTrue(member.schemes.isKnownSplit("member1"))
    try await member.sessions.logout()
    try await member.sessions.login(username: "member1", password: "Bicycle tomato harvest 9")
    XCTAssertEqual(member.vault.keyPair(for: try XCTUnwrap(member.sessions.state.user?.id))?.privateKey, memberKey, "the same key, now under the wrap key")
    let groupState = await member.group.refreshKeyState()
    XCTAssertTrue(groupState.isReady, "and the group key still opens with it")
    await assertThrowsAppError(try await member.sessions.login(username: "member1", password: "password1")) { XCTAssertTrue($0.isUnauthorized, "the old password is gone, and there is no fallback for a known split name") }
    try await member.sessions.login(username: "member1", password: "Bicycle tomato harvest 9")

    // 3. A newcomer claims: split, with the group-made key re-wrapped under the wrap key.
    // On an end-to-end server a managed writer's keypair is made by a member's phone, so the seed adds none: add one here.
    let writer = try await member.group.addWriter(name: "Alex (iOS split test)", email: nil, note: nil)
    let issued = try await member.group.issueToken(writerId: writer.id)
    _ = try await newcomer.sessions.claimInfo(token: issued.token)
    let username = "alexios\(Int(Date().timeIntervalSince1970) % 100_000)"
    try await newcomer.sessions.claim(token: issued.token, username: username, password: "Lantern river quiet map 4", email: nil)
    let claimedScheme = try await scheme(base, username)
    XCTAssertEqual(claimedScheme, "split")
    XCTAssertTrue(newcomer.schemes.isKnownSplit(username))
    let newcomerId = try XCTUnwrap(newcomer.sessions.state.user?.id)
    let newcomerKey = try Data(XCTUnwrap(newcomer.vault.keyPair(for: newcomerId)).privateKey)
    let recoveryCode = try XCTUnwrap(newcomer.sessions.pendingRecoveryCode)
    newcomer.sessions.recoveryCodeSaved()

    // 4. Letters sealed under keys wrapped this way open on both sides.
    // As the compose screen does in end-to-end mode: the relay group is resolved first, so the letter is sealed to it.
    let groupId = try XCTUnwrap(member.sessions.state.user?.chapterId)
    let sent = try await newcomer.letters.send(NewLetter(prisonerId: 1, body: "Sealed after a split claim.", relayNote: nil, relayChapter: groupId, groupRelaysFacility: true))
    let queue = try await member.group.queue(groupId: groupId, status: .queued, page: 1, pageSize: 100)
    XCTAssertEqual(queue.items.first { $0.id == sent.id }?.letter.body, "Sealed after a split claim.", "the group reads it with the group key")
    try await newcomer.sessions.logout()
    try await newcomer.sessions.login(username: username, password: "Lantern river quiet map 4")
    XCTAssertEqual(newcomer.vault.keyPair(for: newcomerId)?.privateKey, newcomerKey)
    let reread = try await newcomer.letters.letter(messageId: sent.id)
    XCTAssertEqual(reread.body, "Sealed after a split claim.", "and the writer reads it again after a one-derivation sign-in")

    // 5. Recovery sets a split password too, and keeps the key.
    try await newcomer.sessions.logout()
    try await newcomer.sessions.recover(username: username, recoveryCode: recoveryCode, newPassword: "Harbour candle seven wolves")
    XCTAssertEqual(newcomer.vault.keyPair(for: newcomerId)?.privateKey, newcomerKey)
    let recoveredScheme = try await scheme(base, username)
    XCTAssertEqual(recoveredScheme, "split")

    // 6. Deleting proves the auth key, not the password: a wrong one deletes nothing.
    await assertThrowsAppError(try await newcomer.accountDeletion.deleteMyAccount(password: "Lantern river quiet map 4")) { XCTAssertEqual($0, AccountDeletion.wrongPassword) }
    let gone = try await newcomer.accountDeletion.deleteMyAccount(password: "Harbour candle seven wolves")
    print("live #114: the newcomer's account deleted: \(gone)")
    XCTAssertFalse(newcomer.sessions.state.isSignedIn)
  }

  /// Group roles (API PR #115) on an end-to-end server with the flag on: the first group admin to set up the key
  /// owns it; a second is waiting with nothing to press; only the owner hands, and passes the role on; the
  /// server refuses an owner's deletion with a coded condition (PR #117). Needs a second group admin, which
  /// under the flag an admin cannot create, so the throwaway is seeded with `member2` before the flag goes on.
  ///
  ///     ABC_LIVE_THROWAWAY=http://localhost:3199 swift test --filter testThrowawayServerGroupRoles
  func testThrowawayServerGroupRoles() async throws {
    let sam = try container("ABC_LIVE_THROWAWAY"), noor = try container("ABC_LIVE_THROWAWAY")
    let base = try XCTUnwrap(env("ABC_LIVE_THROWAWAY"))
    for port in [":3000", ":3100", ":3069"] { XCTAssertFalse(base.contains(port), "that is a development server people use; this test moves ownership") }
    await sam.modes.refresh(); await noor.modes.refresh()
    try XCTSkipIf(sam.modes.mode != .e2e, "written for an end-to-end server")

    try await sam.sessions.login(username: "member1", password: "password1")
    sam.sessions.recoveryCodeSaved()
    let setUp = await sam.group.setUpKeys()
    XCTAssertTrue(setUp.madeGroupKey || sam.group.keyState.isReady)
    guard case .ready(let samsKey) = sam.group.keyState else { return XCTFail("member1's group key") }
    XCTAssertTrue(samsKey.isOwner, "the first group admin to set up the key becomes the owner")
    let samId = try XCTUnwrap(sam.sessions.state.user?.id)

    try await noor.sessions.login(username: "member2", password: "password2")
    noor.sessions.recoveryCodeSaved()
    let noorId = try XCTUnwrap(noor.sessions.state.user?.id)
    var roster = try await sam.group.roster()
    print("live #115: member1 sees owner \(roster.ownerId ?? -1), waiting \(roster.waiting.map(\.name))")
    XCTAssertEqual(roster.ownerId, samId); XCTAssertTrue(roster.iAmOwner); XCTAssertTrue(roster.waiting.contains { $0.id == noorId })
    let hers = try await noor.group.roster()
    XCTAssertFalse(hers.iAmOwner); XCTAssertEqual(hers.ownerId, samId)
    await assertThrowsAppError(try await noor.group.handKey(to: samId)) {
      print("live #115: a group admin who is not the owner is refused: \($0.userMessage ?? "nil")")
      XCTAssertTrue($0.isForbidden)
    }

    // Only beside a holder: the phone refuses before asking; after handing, the role passes.
    let waiting = try XCTUnwrap(roster.members.first { $0.id == noorId })
    await assertThrowsAppError(try await sam.group.makeOwner(waiting)) { XCTAssertEqual($0, GroupRepository.handKeyFirst) }
    try await sam.group.handKey(to: noorId)
    let noorsKey = await noor.group.refreshKeyState()
    XCTAssertTrue(noorsKey.isReady, "handed: \(noorsKey)")
    roster = try await sam.group.roster()
    try await sam.group.makeOwner(try XCTUnwrap(roster.members.first { $0.id == noorId }))
    roster = try await sam.group.roster()
    XCTAssertEqual(roster.ownerId, noorId); XCTAssertFalse(roster.iAmOwner)
    guard case .ready(let samsKeyNow) = sam.group.keyState else { return XCTFail() }
    XCTAssertFalse(samsKeyNow.isOwner, "the loaded key was reloaded")
    await assertThrowsAppError(try await sam.group.handKey(to: noorId)) { XCTAssertTrue($0.isForbidden, "the old owner has lost the right") }
    let hersNow = try await noor.group.roster()
    XCTAssertTrue(hersNow.iAmOwner)
    guard case .ready(let noorsKeyNow) = await noor.group.refreshKeyState() else { return XCTFail() }
    XCTAssertTrue(noorsKeyNow.isOwner)

    // The feed, from the server's own events.
    let samsNews = await sam.activity.sync()
    print("live #115: member1's feed says: \(samsNews.map(\.sentence))")
    XCTAssertTrue(samsNews.contains { $0.kind == .groupOwner(me: false) })
    let noorsNews = await noor.activity.sync()
    print("live #115: member2's feed says: \(noorsNews.map(\.sentence))")
    XCTAssertTrue(noorsNews.contains { $0.kind == .groupKeyHanded(toMe: true) }); XCTAssertTrue(noorsNews.contains { $0.kind == .groupOwner(me: true) })

    // Leaving: the owner with another group admin is refused by the server with a coded condition (PR #117).
    let preview = await noor.accountDeletion.preview()
    XCTAssertTrue(preview.isOwnerWithOtherAdmins)
    await assertThrowsAppError(try await noor.sessions.deleteAccount(password: "password2")) {
      print("live #115/#117: the server refuses the owner's deletion with condition \($0.conflictCondition ?? "none"): \($0.userMessage ?? "")")
      XCTAssertEqual($0.conflictCondition, "group_owner")
    }
    XCTAssertTrue(noor.sessions.state.isSignedIn)
    let samsPreview = await sam.accountDeletion.preview()
    XCTAssertFalse(samsPreview.isOwnerWithOtherAdmins)
  }
}
