@testable import ABCCore
import ABCCrypto
import XCTest

/// A group's share of the move to end-to-end encryption (API PR #95), walked through in the order it
/// happens in the world: first while the server is in server mode, then after the switch.
@MainActor
final class KeySetUpTests: XCTestCase {
  private var fake: FakeAPI!

  override func setUp() async throws {
    fake = FakeAPI()
    fake.mode = "server"
    fake.accounts = [
      FakeAPI.Account(id: 9, username: "member1", password: "password1", role: "chapter", chapterId: 1, name: "Sam"),
      FakeAPI.Account(id: 10, username: "member2", password: "password2", role: "chapter", chapterId: 1, name: "Noor"),
      FakeAPI.Account(id: 4, username: "user1", password: "password1"),
      FakeAPI.Account(id: 47, username: "managed-47", password: "unknowable", managedBy: 1, name: "Alex"),
      FakeAPI.Account(id: 48, username: "anon-1", password: "unknowable", managedBy: 1, name: "Anonymous", anonymousFor: 1),
    ]
  }

  private func phone(_ username: String, _ password: String) async throws -> TestApp {
    let fake = fake!
    let app = TestApp { fake.handle($0) }
    try await app.container.sessions.login(username: username, password: password)
    app.container.sessions.recoveryCodeSaved()
    return app
  }

  func testAWritersAccountHasNothingToDo() async throws {
    let writer = try await phone("user1", "password1")
    let done = await writer.container.group.setUpKeys()
    XCTAssertEqual(done, GroupRepository.KeySetUp())
    XCTAssertEqual(writer.requests(to: "/auth/chapter-keys").count, 0)
  }

  func testInServerModeTheFirstMemberToSignInMakesTheGroupKeyAndGivesWritersTheirs() async throws {
    let sam = try await phone("member1", "password1")
    let done = await sam.container.group.setUpKeys()
    XCTAssertTrue(done.madeGroupKey, "this is the step the switch actually waits for")
    XCTAssertEqual(done.writersGivenKeys, 1, "Alex; the shared anonymous account is not a person and never has keys")
    XCTAssertEqual(done.lettersShared, 0); XCTAssertEqual(done.membersWaiting, [])
    XCTAssertNotNil(fake.groupKeys[1]); XCTAssertNotNil(fake.memberKeys[1]?[9])
    XCTAssertNil(fake.accounts[4].keys["publicKey"])
    XCTAssertEqual(sam.requests(to: "/messaging/envelopes/missing").count, 0, "there are no envelopes before the switch")

    // Alex's key really is in the group's custody: group key -> writer key.
    let alex = fake.accounts[3]
    let groupKey = try XCTUnwrap(sam.container.keyring.groupKey())
    let opened = try GroupKeys.open(try XCTUnwrap(alex.orgWrappedPrivateKey), holder: groupKey.keyPair, expectedPublicKey: alex.keys["publicKey"] as? String)
    XCTAssertEqual(Sodium.toBase64(opened.publicKey), alex.keys["publicKey"] as? String)
    let put = try XCTUnwrap(sam.requests(to: "/auth/user", method: "PUT").first).json
    XCTAssertEqual(Set(put.keys), ["id", "publicKey", "orgWrappedPrivateKey", "orgKeyVersion"], "all three together; the public key alone is a 400")

    // Again, there is nothing left to do, and nothing is done twice.
    let again = await sam.container.group.setUpKeys()
    XCTAssertEqual(again, GroupRepository.KeySetUp())
    XCTAssertEqual(sam.requests(to: "/auth/chapter-keys").count, 1); XCTAssertEqual(sam.requests(to: "/auth/user", method: "PUT").count, 1)
  }

  func testASecondMemberWaitsForAHolderWhoIsToldAndHandsTheKeyOver() async throws {
    let sam = try await phone("member1", "password1")
    _ = await sam.container.group.setUpKeys()

    // Noor signs in: her own keys are made, the group key exists, and she does not hold it.
    let noor = try await phone("member2", "password2")
    let hers = await noor.container.group.setUpKeys()
    XCTAssertFalse(hers.madeGroupKey); XCTAssertEqual(hers, GroupRepository.KeySetUp(), "she can do nothing yet, and makes no second group key")
    XCTAssertEqual(noor.requests(to: "/auth/chapter-keys").count, 0)

    // Sam's phone finds her waiting the next time it looks. Handing the key over is left to a person.
    let next = await sam.container.group.setUpKeys()
    XCTAssertEqual(next.membersWaiting.map(\.name), ["Noor"])
    XCTAssertNil(fake.memberKeys[1]?[10], "not handed over without being asked")
    try await sam.container.group.handKey(to: 10)
    let after = await sam.container.group.setUpKeys()
    XCTAssertEqual(after.membersWaiting, [])
    guard case .ready = await noor.container.keyring.load(force: true, anyMode: true) else { return XCTFail("Noor should hold the key now") }
  }

  func testAWriterAddedInServerModeGetsKeysStraightAway() async throws {
    let sam = try await phone("member1", "password1")
    _ = await sam.container.group.setUpKeys()
    let maria = try await sam.container.group.addWriter(name: "Maria", email: nil, note: nil)
    XCTAssertNil(try XCTUnwrap(sam.requests(to: "/auth/writer", method: "POST").first).json["publicKey"], "server mode creates the account the plain way")
    let stored = try XCTUnwrap(fake.accounts.first { $0.id == maria.id })
    XCTAssertNotNil(stored.keys["publicKey"]); XCTAssertNotNil(stored.orgWrappedPrivateKey)
  }

  func testAfterTheSwitchAReplyForAWriterWithNoKeysIsSealedToTheGroupAndSharedOnceTheyHaveThem() async throws {
    let sam = try await phone("member1", "password1")
    _ = await sam.container.group.setUpKeys()
    fake.mode = "e2e" // the switch. user1 has not signed in since keys existed.
    await sam.container.modes.refresh()

    // A letter written *for* someone with no key is refused; a reply recorded for them is not.
    await assertThrowsAppError(try await sam.container.letters.send(NewLetter(prisonerId: 3, body: "Dear Jane", relayNote: nil, relayChapter: nil, asWriterId: 4))) { XCTAssertEqual($0, LetterCodec.writerHasNoKey) }
    let reply = try await sam.container.letters.send(NewLetter(prisonerId: 3, body: "Thank you for writing.", relayNote: nil, relayChapter: nil, asWriterId: 4, fromPrisoner: true))
    XCTAssertEqual((fake.messages.last?["envelopes"] as? [[String: Any]])?.map { "\($0["readerType"]!) \($0["readerId"]!)" }, ["chapter 1"])

    // The writer signs in: keys are made, and the reply is there but not theirs to open yet.
    let writer = try await phone("user1", "password1")
    let waiting = try await writer.container.letters.letter(messageId: reply.id)
    XCTAssertTrue(waiting.awaitingShare, "not an empty letter, and not a locked one"); XCTAssertFalse(waiting.locked); XCTAssertEqual(waiting.body, "")

    // The next time a member's phone looks, it shares the letter.
    let done = await sam.container.group.setUpKeys()
    XCTAssertEqual(done.lettersShared, 1)
    let opened = try await writer.container.letters.letter(messageId: reply.id)
    XCTAssertEqual(opened.body, "Thank you for writing."); XCTAssertFalse(opened.awaitingShare)
    let again = await sam.container.group.setUpKeys()
    XCTAssertEqual(again.lettersShared, 0)
  }

  func testAMemberWhoseOwnKeyIsLockedDoesNothingAndBreaksNothing() async throws {
    let sam = try await phone("member1", "password1")
    sam.container.vault.clear()
    let done = await sam.container.group.setUpKeys()
    XCTAssertEqual(done, GroupRepository.KeySetUp())
    XCTAssertNil(fake.groupKeys[1])
  }
}
