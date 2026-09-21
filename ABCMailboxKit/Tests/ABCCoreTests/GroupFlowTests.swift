@testable import ABCCore
import ABCCrypto
import XCTest

/// The group's side of end-to-end encryption, from key set-up to a claimed account.
@MainActor
final class GroupFlowTests: XCTestCase {
  private var fake: FakeAPI!
  private var app: TestApp!
  private var group: GroupRepository { app.container.group }

  override func setUp() async throws {
    fake = FakeAPI()
    fake.accounts = [
      FakeAPI.Account(id: 9, username: "member1", password: "password1", role: "chapter", chapterId: 1, name: "Sam"),
      FakeAPI.Account(id: 10, username: "member2", password: "password2", role: "chapter", chapterId: 1, name: "Noor"),
      FakeAPI.Account(id: 4, username: "user1", password: "password1"),
    ]
    let fake = fake!
    app = TestApp { fake.handle($0) }
  }

  private func signIn(_ username: String = "member1", _ password: String = "password1") async throws {
    try await app.container.sessions.login(username: username, password: password)
    app.container.sessions.recoveryCodeSaved()
  }

  private func stateName(_ s: GroupKeyState) -> String {
    switch s { case .notNeeded: "notNeeded"; case .locked: "locked"; case .notSetUp: "notSetUp"; case .notHeld: "notHeld"; case .groupNotActive: "groupNotActive"; case .ready: "ready"; case .failed: "failed" }
  }

  func testAWriterNeverNeedsTheKeyringAndInServerModeReadingNeverWaitsForIt() async throws {
    try await signIn("user1")
    let asWriter = await group.refreshKeyState()
    XCTAssertEqual(stateName(asWriter), "notNeeded")
    try await app.container.sessions.logout()

    fake.mode = "server"
    await app.container.modes.refresh()
    try await signIn()
    let before = app.requests(to: "/auth/keys", method: "GET").count
    _ = try await group.queue(groupId: 1, status: .queued, page: 1, pageSize: 20)
    XCTAssertEqual(app.requests(to: "/auth/keys", method: "GET").count, before, "the server reads for everyone; the queue does not ask for keys")
    // Asked directly (the key set-up after sign-in does), the truth is told in either mode.
    let inServerMode = await group.refreshKeyState()
    XCTAssertEqual(stateName(inServerMode), "notSetUp")
  }

  func testAGroupSetsItsKeyUpOnceHandsItOnAndASecondMemberOpensIt() async throws {
    try await signIn()
    let before = await group.refreshKeyState()
    XCTAssertEqual(stateName(before), "notSetUp")

    try await group.setUpGroupKey()
    XCTAssertTrue(group.keyState.isReady)
    // A second set-up (another member got there first) is refused, and the key in force is the first one.
    // Reloading wipes the copy that was in memory, so the key is read from the state afterwards, not before.
    await assertThrowsAppError(try await group.setUpGroupKey()) { XCTAssertTrue($0.isConflict) }
    guard case .ready(let key) = group.keyState else { return XCTFail("expected the key to be open, got \(stateName(group.keyState))") }
    XCTAssertEqual(key.version, 1)
    XCTAssertEqual(Sodium.toBase64(key.keyPair.publicKey), fake.groupKeys[1]?.publicKey)

    // Noor has never signed in, so there is nothing to seal the key to.
    var members = try await group.members()
    XCTAssertEqual(members.map { "\($0.name) own:\($0.hasOwnKey) holds:\($0.holdsGroupKey) me:\($0.isMe)" }, ["Sam own:true holds:true me:true", "Noor own:false holds:false me:false"])
    await assertThrowsAppError(try await group.handKey(to: 10)) { guard case .validation = $0 else { return XCTFail() } }

    // Noor signs in on her own phone (her keypair is made), and is told she has not been given the key.
    let fake = fake!
    let noor = TestApp { fake.handle($0) }
    try await noor.container.sessions.login(username: "member2", password: "password2")
    let waiting = await noor.container.group.refreshKeyState()
    XCTAssertEqual(stateName(waiting), "notHeld")

    try await group.handKey(to: 10)
    members = try await group.members()
    XCTAssertEqual(members.map(\.holdsGroupKey), [true, true])
    guard case .ready(let hers) = await noor.container.group.refreshKeyState() else { return XCTFail("Noor should hold the key now") }
    XCTAssertEqual(hers.keyPair.privateKey, key.keyPair.privateKey)

    try await group.stopHandingKey(to: 10)
    XCTAssertNil(fake.memberKeys[1]?[10])
  }

  func testASubstitutedGroupKeyIsRefusedNotUsed() async throws {
    try await signIn()
    try await group.setUpGroupKey()
    // The server (or someone in between) publishes a different public key than the sealed private key belongs to.
    fake.groupKeys[1] = (Sodium.toBase64(Sodium.keypair().publicKey), 1)
    let state = await group.refreshKeyState()
    XCTAssertEqual(stateName(state), "notHeld")
    await assertThrowsAppError(try await group.addWriter(name: "Alex", email: nil, note: nil))
  }

  func testTheWholeCustodyChainInTheApp_AddAWriterWriteForThemHandOffAndClaim() async throws {
    try await signIn()
    try await group.setUpGroupKey()

    // Add a writer: the keypair is made on this phone and its private half sealed to the group.
    let alex = try await group.addWriter(name: " Alex ", email: "", note: "Met at the letter night")
    let added = try XCTUnwrap(app.requests(to: "/auth/writer", method: "POST").first).json
    XCTAssertEqual(added["name"] as? String, "Alex"); XCTAssertNil(added["email"]); XCTAssertEqual(added["orgKeyVersion"] as? Int, 1)
    XCTAssertEqual(try Sodium.fromBase64(added["publicKey"] as! String).count, 32)
    XCTAssertEqual(try Sodium.fromBase64(added["orgWrappedPrivateKey"] as! String).count, 80)
    let writers = try await group.writers()
    XCTAssertEqual(writers.map(\.name), ["Alex"]); XCTAssertNil(writers[0].email, "the placeholder address is not shown")

    // Write for them: sealed to the writer and to the managing group; nothing else.
    let sent = try await app.container.letters.send(NewLetter(prisonerId: 3, body: "Dear Jane", relayNote: nil, relayChapter: 1, asWriterId: alex.id))
    XCTAssertEqual(sent.body, "Dear Jane")
    let post = try XCTUnwrap(app.requests(to: "/messaging/message", method: "POST").first).json
    XCTAssertEqual((post["envelopes"] as? [[String: Any]])?.map { "\($0["readerType"]!) \($0["readerId"]!)" }, ["user \(alex.id)", "chapter 1"])
    XCTAssertEqual(post["user"] as? Int, alex.id)

    // The queue shows it, addressed.
    let queue = try await group.queue(groupId: 1, status: .queued, page: 1, pageSize: 20)
    XCTAssertEqual(queue.items.map(\.letter.body), ["Dear Jane"])
    XCTAssertEqual(queue.items.first?.prisoner?.inmateId, "A-3")
    XCTAssertEqual(app.requests(to: "/prisoner/prisoner").count, 0, "since API PR #111 the row brings the prisoner with it")

    // Forward only.
    let printed = try await group.setStatus(messageId: sent.id, status: .printed)
    XCTAssertEqual(printed.status, .printed); XCTAssertEqual(printed.body, "Dear Jane")
    await assertThrowsAppError(try await group.setStatus(messageId: sent.id, status: .queued)) { XCTAssertEqual($0.userMessage, "A printed letter cannot move to queued.") }

    // After a relaunch the custody key comes back through member key -> group key -> writer key, not from memory.
    let fake = fake!
    let relaunched = TestApp(secrets: app.secrets) { fake.handle($0) }
    let reread = try await relaunched.container.letters.letter(messageId: sent.id)
    XCTAssertEqual(reread.body, "Dear Jane")

    // Hand off: the token is made here; the server gets a hash and the key wrapped under the token.
    let issued = try await relaunched.container.group.issueToken(writerId: alex.id)
    XCTAssertTrue(SecretCodes.isWellFormed(issued.token))
    let tokenRequest = try XCTUnwrap(relaunched.requests(to: "/auth/writer/token", method: "POST").first)
    XCTAssertFalse(tokenRequest.bodyText.contains(issued.token), "the token itself never leaves the phone")
    XCTAssertEqual(tokenRequest.json["tokenHash"] as? String, SecretCodes.hashHex(issued.token))

    // Alex claims on their own phone and reads the letter the group wrote for them.
    let theirs = TestApp { fake.handle($0) }
    _ = try await theirs.container.sessions.claimInfo(token: issued.token)
    try await theirs.container.sessions.claim(token: issued.token, username: "alex", password: "my own password", email: nil)
    let asAlex = try await theirs.container.letters.letter(messageId: sent.id)
    XCTAssertEqual(asAlex.body, "Dear Jane")
    let afterClaim = try await relaunched.container.group.writers()
    XCTAssertEqual(afterClaim, [], "once claimed, they are no longer among the group's writers")
  }

  func testAnAnonymousLetterHasOneEnvelopeAndARecordedReplyIsSealedToTheWriterOnlyUnlessTheGroupRelays() async throws {
    try await signIn()
    try await group.setUpGroupKey()
    // The independent writer needs a keypair before anything can be sealed to them.
    let fake = fake!
    let writerApp = TestApp { fake.handle($0) }
    try await writerApp.container.sessions.login(username: "user1", password: "password1")

    _ = try await app.container.letters.send(NewLetter(prisonerId: 3, body: "From a friend", relayNote: nil, relayChapter: 1))
    _ = try await app.container.letters.send(NewLetter(prisonerId: 3, body: "Thank you", relayNote: "ignored", relayChapter: 2, asWriterId: 4, fromPrisoner: true))
    _ = try await app.container.letters.send(NewLetter(prisonerId: 3, body: "Thank you again", relayNote: nil, relayChapter: nil, asWriterId: 4, fromPrisoner: true, groupRelaysFacility: true))
    let posts = app.requests(to: "/messaging/message", method: "POST").map(\.json)
    func readers(_ p: [String: Any]) -> [String] { (p["envelopes"] as? [[String: Any]] ?? []).map { "\($0["readerType"]!) \($0["readerId"]!)" } }
    XCTAssertEqual(readers(posts[0]), ["chapter 1"]); XCTAssertNil(posts[0]["user"]); XCTAssertEqual(posts[0]["sender"] as? String, "user")
    XCTAssertEqual(readers(posts[1]), ["user 4"]); XCTAssertEqual(posts[1]["sender"] as? String, "prisoner")
    XCTAssertNil(posts[1]["relayChapter"]); XCTAssertNil(posts[1]["relayNoteCiphertext"], "a reply is not relayed anywhere")
    XCTAssertEqual(readers(posts[2]), ["user 4", "chapter 1"])

    // The writer reads the recorded reply on their own phone.
    let replyId = try XCTUnwrap(fake.messages[1]["id"] as? Int)
    let reply = try await writerApp.container.letters.letter(messageId: replyId)
    XCTAssertEqual(reply.body, "Thank you"); XCTAssertTrue(reply.fromPrisoner)
  }

  func testAMemberWithoutTheGroupKeyIsToldWhyAndNothingIsSent() async throws {
    try await signIn()
    try await group.setUpGroupKey()
    try await app.container.sessions.logout()
    try await signIn("member2", "password2")
    await assertThrowsAppError(try await app.container.letters.send(NewLetter(prisonerId: 3, body: "Hi", relayNote: nil, relayChapter: 1))) {
      guard case .forbidden(let info) = $0 else { return XCTFail("expected forbidden") }
      XCTAssertTrue(info.contains("not been given your group's key"))
    }
    XCTAssertEqual(app.requests(to: "/messaging/message").count, 0)
  }

  func testSharingSealsTheLettersOwnContentKeyToAnActivePartnerGroup() async throws {
    try await signIn()
    try await group.setUpGroupKey()
    let partner = Sodium.keypair()
    fake.groupKeys[2] = (Sodium.toBase64(partner.publicKey), 5)
    let sent = try await app.container.letters.send(NewLetter(prisonerId: 3, body: "Dear Jane", relayNote: nil, relayChapter: 1))

    let partners = await group.partners(forPrisoner: 3)
    XCTAssertEqual(partners.map(\.name), ["Partner Chapter"], "not our own group, not a suspended one")
    try await group.share(messageId: sent.id, withGroup: 2)
    let envelope = try XCTUnwrap(app.requests(to: "/messaging/envelope").first).json
    XCTAssertEqual(envelope["keyVersion"] as? Int, 5); XCTAssertEqual(envelope["message"] as? Int, sent.id)
    let key = try LetterCipher.openEnvelope(envelope["wrappedKey"] as! String, keyPair: partner)
    let stored = try XCTUnwrap(fake.messages.first)
    XCTAssertEqual(try LetterCipher.decryptText(ciphertext: stored["ciphertext"] as! String, nonce: stored["nonce"] as! String, contentKey: key), "Dear Jane")
  }

  func testSigningOutForgetsTheGroupKey() async throws {
    try await signIn()
    try await group.setUpGroupKey()
    XCTAssertTrue(group.keyState.isReady)
    try await app.container.sessions.logout()
    XCTAssertEqual(stateName(group.keyState), "notNeeded")
  }

  func testServerModeAsksTheServerForTheTokenAndCanRevokeIt() async throws {
    fake.mode = "server"
    try await signIn()
    let alex = try await group.addWriter(name: "Alex", email: nil, note: nil)
    XCTAssertNil(try XCTUnwrap(app.requests(to: "/auth/writer", method: "POST").first).json["publicKey"])
    let issued = try await group.issueToken(writerId: alex.id)
    XCTAssertTrue(SecretCodes.isWellFormed(issued.token)); XCTAssertNotNil(issued.expiresAt)
    let pending = try await group.writers()
    XCTAssertTrue(pending[0].hasLiveToken)
    try await group.revokeToken(writerId: alex.id)
    XCTAssertEqual(try XCTUnwrap(app.requests(to: "/auth/writer/token", method: "DELETE").first).json as NSDictionary, ["writer": alex.id])
    let revoked = try await group.writers()
    XCTAssertFalse(revoked[0].hasLiveToken)
  }
}
