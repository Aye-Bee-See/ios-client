@testable import ABCCore
import XCTest

/// Deleting one's own account (API PR #104). Two promises: nothing goes unless the server says it went,
/// and once it has, this phone keeps nothing either.
@MainActor
final class AccountDeletionTests: XCTestCase {
  private var fake: FakeAPI!
  private var app: TestApp!
  private var deletion: AccountDeletion { app.container.accountDeletion }

  override func setUp() async throws {
    fake = FakeAPI()
    fake.mode = "server"
    fake.accounts = [
      FakeAPI.Account(id: 4, username: "user1", password: "password1"),
      FakeAPI.Account(id: 9, username: "member1", password: "password1", role: "chapter", chapterId: 1, name: "Sam"),
      FakeAPI.Account(id: 10, username: "member2", password: "password2", role: "chapter", chapterId: 1, name: "Noor"),
    ]
    let fake = fake!
    app = TestApp { fake.handle($0) }
  }

  private func signIn(_ username: String = "user1", _ password: String = "password1") async throws {
    try await app.container.sessions.login(username: username, password: password)
    app.container.sessions.recoveryCodeSaved()
  }

  func testTheAccountGoesWithEverythingAndThisPhoneKeepsNothing() async throws {
    try await signIn()
    _ = try await app.container.letters.send(NewLetter(prisonerId: 3, body: "Dear Jane", relayNote: nil, relayChapter: nil))
    _ = try await app.container.letters.send(NewLetter(prisonerId: 5, body: "Dear Alex", relayNote: nil, relayChapter: nil))
    app.container.drafts.save(userId: 4, prisonerId: 7, draft: Draft(body: "half a letter", note: nil, relayChapter: nil))
    app.container.drafts.save(userId: 9, prisonerId: 7, draft: Draft(body: "someone else's draft", note: nil, relayChapter: nil))
    fake.noSignal = true
    try app.container.outbox.queue(prisonerName: "Jane Smith", writingAs: nil, letter: NewLetter(prisonerId: 3, body: "Written offline", relayNote: nil, relayChapter: nil), attachments: [])
    fake.noSignal = false
    fake.tell(4, "letter.reply")
    _ = await app.container.activity.sync()

    let preview = await deletion.preview()
    XCTAssertEqual(preview.conversations, 2); XCTAssertEqual(preview.unsentLetters, 1); XCTAssertFalse(preview.isLastKeyHolder)

    let gone = try await deletion.deleteMyAccount(password: "password1")
    XCTAssertEqual(gone, DeletedAccount(letters: 2, replies: 0, attachments: 0, threads: 1, unsentLetters: 1))
    XCTAssertEqual(try XCTUnwrap(app.requests(to: "/auth/user", method: "DELETE").first).json as NSDictionary, ["id": 4, "password": "password1"])

    // On the server: gone. On this phone: signed out, no key, no drafts, no unsent letters, no place in a feed.
    XCTAssertNil(fake.accounts.first { $0.id == 4 }); XCTAssertEqual(fake.messages.count, 0)
    XCTAssertFalse(app.container.sessions.state.isSignedIn)
    XCTAssertNil(app.secrets.read("session")); XCTAssertNil(app.secrets.read("key_vault")); XCTAssertNil(app.container.vault.keyPair(for: 4))
    XCTAssertNil(app.container.drafts.load(userId: 4, prisonerId: 7))
    XCTAssertEqual(app.container.drafts.load(userId: 9, prisonerId: 7)?.body, "someone else's draft", "another account on this phone is not touched")
    XCTAssertFalse(FileManager.default.fileExists(atPath: app.scratch.appendingPathComponent("outbox/4").path))
    XCTAssertEqual(app.container.activity.unread, 0)
    XCTAssertNil(app.defaults.object(forKey: "activity_last_seen_4"))
    await assertThrowsAppError(try await app.container.sessions.login(username: "user1", password: "password1")) { XCTAssertTrue($0.isUnauthorized) }
  }

  func testAWrongPasswordDeletesNothingHereOrThereAndDoesNotSignAnyoneOut() async throws {
    try await signIn()
    app.container.drafts.save(userId: 4, prisonerId: 7, draft: Draft(body: "half a letter", note: nil, relayChapter: nil))
    await assertThrowsAppError(try await deletion.deleteMyAccount(password: "a guess")) {
      XCTAssertEqual($0, .forbidden("That is not this account's password. Nothing was deleted."))
    }
    XCTAssertNotNil(fake.accounts.first { $0.id == 4 })
    XCTAssertEqual(app.requests(to: "/auth/user", method: "DELETE").count, 0, "the phone proves the password first; a wrong one never reaches the delete")
    XCTAssertTrue(app.container.sessions.state.isSignedIn); XCTAssertEqual(app.container.sessions.expiredCount, 0)
    XCTAssertNotNil(app.container.vault.keyPair(for: 4))
    XCTAssertEqual(app.container.drafts.load(userId: 4, prisonerId: 7)?.body, "half a letter")
  }

  func testAServerFromBeforePR104WhichIgnoresThePasswordStillCannotBeMadeToDeleteWithAWrongOne() async throws {
    // Found on the simulator, 20 September 2026: a development server started before the merge deleted
    // an account given a wrong password, because its handler never reads the field.
    fake.predatesPasswordOnDelete = true
    try await signIn()
    _ = try await app.container.letters.send(NewLetter(prisonerId: 3, body: "Dear Jane", relayNote: nil, relayChapter: nil))
    await assertThrowsAppError(try await deletion.deleteMyAccount(password: "a guess")) { XCTAssertEqual($0, AccountDeletion.wrongPassword) }
    XCTAssertNotNil(fake.accounts.first { $0.id == 4 }); XCTAssertEqual(fake.messages.count, 1)
    XCTAssertEqual(app.requests(to: "/auth/user", method: "DELETE").count, 0)
    XCTAssertTrue(app.container.sessions.state.isSignedIn)

    // Guesses are limited like failed sign-ins, and the limit is shown, not mistaken for a wrong password.
    fake.intercept = { $0.path == "/auth/login" ? .error(429, info: "Too many sign-in attempts. Try again in 15 minute(s).") : nil }
    await assertThrowsAppError(try await deletion.deleteMyAccount(password: "password1")) { guard case .rateLimited = $0 else { return XCTFail("expected the rate limit, got \($0)") } }
    XCTAssertNotNil(fake.accounts.first { $0.id == 4 })

    // The right password still works against the old server.
    try await deletion.deleteMyAccount(password: "password1")
    XCTAssertNil(fake.accounts.first { $0.id == 4 })
  }

  func testNoAnswerFromTheServerDeletesNothingOnThePhoneEither() async throws {
    try await signIn()
    app.container.drafts.save(userId: 4, prisonerId: 7, draft: Draft(body: "half a letter", note: nil, relayChapter: nil))
    fake.noSignal = true
    await assertThrowsAppError(try await deletion.deleteMyAccount(password: "password1")) { XCTAssertEqual($0, .network) }
    XCTAssertTrue(app.container.sessions.state.isSignedIn)
    XCTAssertEqual(app.container.drafts.load(userId: 4, prisonerId: 7)?.body, "half a letter")
    for answer in [Stubbed.error(429, info: "Too many attempts. Try again in 15 minute(s)."), .error(503, info: "Down.")] {
      fake.noSignal = false
      fake.intercept = { $0.path == "/auth/user" && $0.method == "DELETE" ? answer : nil }
      await assertThrowsAppError(try await deletion.deleteMyAccount(password: "password1"))
      XCTAssertTrue(app.container.sessions.state.isSignedIn)
    }
  }

  func testTheLastHolderOfAGroupKeyIsWarnedBeforehandAndRefusedByTheServerUntilTheKeyIsHandedOn() async throws {
    fake.mode = "e2e"
    try await signIn("member1")
    try await app.container.group.setUpGroupKey()
    // Noor has signed in on her own phone, so she has keys and could be handed the group's.
    let fake = fake!
    let noor = TestApp { fake.handle($0) }
    try await noor.container.sessions.login(username: "member2", password: "password2")

    let preview = await deletion.preview()
    XCTAssertTrue(preview.endToEnd); XCTAssertTrue(preview.isLastKeyHolder)
    XCTAssertEqual(preview.membersWhoCouldHoldTheKey, ["Noor"]); XCTAssertNil(preview.conversations, "the group's conversations stay; no number is promised")
    await assertThrowsAppError(try await deletion.deleteMyAccount(password: "password1")) {
      XCTAssertTrue($0.isConflict); XCTAssertTrue(try! XCTUnwrap($0.userMessage).contains("last holder"))
    }
    XCTAssertTrue(app.container.sessions.state.isSignedIn)

    try await app.container.group.handKey(to: 10)
    let after = await deletion.preview()
    XCTAssertFalse(after.isLastKeyHolder)
    try await deletion.deleteMyAccount(password: "password1")
    XCTAssertNil(fake.accounts.first { $0.id == 9 })
    XCTAssertFalse(app.container.keyring.state.isReady, "the group key went from memory with the session")
    guard case .ready = await noor.container.keyring.load(force: true) else { return XCTFail("the group can still read its letters") }
  }

  func testSignedOutThereIsNothingToDelete() async {
    await assertThrowsAppError(try await deletion.deleteMyAccount(password: "password1")) { XCTAssertTrue($0.isUnauthorized) }
    XCTAssertEqual(app.requests(to: "/auth/user", method: "DELETE").count, 0)
  }
}
