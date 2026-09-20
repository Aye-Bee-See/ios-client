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
}
