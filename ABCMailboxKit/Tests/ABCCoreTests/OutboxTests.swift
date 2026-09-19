@testable import ABCCore
import ABCCrypto
import XCTest

/// Letters written without a connection. The promise under test: whatever goes wrong on the way,
/// the server ends up with exactly one copy of each letter and each file.
@MainActor
final class OutboxTests: XCTestCase {
  private var fake: FakeAPI!
  private var app: TestApp!
  private var outbox: OutboxRepository { app.container.outbox }
  private let relayGroup = Sodium.keypair()

  override func setUp() async throws {
    fake = FakeAPI()
    fake.mode = "server"
    fake.accounts = [FakeAPI.Account(id: 4, username: "user1", password: "password1"), FakeAPI.Account(id: 5, username: "user2", password: "password2")]
    let fake = fake!
    app = TestApp { fake.handle($0) }
    try await app.container.sessions.login(username: "user1", password: "password1")
  }

  private func letter(_ body: String = "Dear Jane, written in the basement.", key: String? = nil) -> NewLetter {
    NewLetter(prisonerId: 3, body: body, relayNote: "two pages", relayChapter: nil, idempotencyKey: key)
  }

  private func staged(_ name: String = "scan.pdf", bytes: Data = Data([1, 2, 3, 4])) throws -> StagedFile {
    try app.container.files.stage(data: bytes, name: name, mimeType: "application/pdf")
  }

  private var outboxFolder: URL { app.scratch.appendingPathComponent("outbox/4") }

  func testAQueuedLetterIsCiphertextOnDiskAndGoesOutOnceWhenTheConnectionReturns() async throws {
    fake.noSignal = true
    await assertThrowsAppError(try await app.container.letters.send(letter())) { XCTAssertTrue($0.meansNotReachingOurServer) }
    try outbox.queue(prisonerName: "Jane Smith", writingAs: nil, letter: letter(), attachments: [try staged()])
    XCTAssertEqual(outbox.items.map(\.payload.prisonerName), ["Jane Smith"]); XCTAssertTrue(outbox.hasWaiting)

    for file in try FileManager.default.contentsOfDirectory(at: outboxFolder, includingPropertiesForKeys: nil) {
      let text = String(decoding: try Data(contentsOf: file), as: UTF8.self)
      XCTAssertFalse(text.contains("basement") || text.contains("Jane"), "\(file.lastPathComponent) is readable on disk")
    }

    let stillOffline = await outbox.flush()
    XCTAssertEqual(stillOffline, FlushOutcome(sent: 0, refused: 0, stillWaiting: 1))
    XCTAssertNil(outbox.items.first?.problem, "no connection is not a refusal")

    fake.noSignal = false
    let online = await outbox.flush()
    XCTAssertEqual(online, FlushOutcome(sent: 1, refused: 0, stillWaiting: 0))
    XCTAssertEqual(outbox.items, [])
    XCTAssertEqual(fake.messages.map { $0["messageText"] as? String }, ["Dear Jane, written in the basement."])
    XCTAssertEqual(fake.attachments.values.map(\.bytes), [Data([1, 2, 3, 4])])
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outboxFolder.path), [], "nothing is left behind")
  }

  func testALetterThatArrivedAlthoughThePhoneNeverHeardSoIsNotSentTwice() async throws {
    // The compose screen's attempt reaches the server, and the answer is lost in a tunnel.
    fake.loseAnswerTo = { $0.path == "/messaging/message" }
    await assertThrowsAppError(try await app.container.letters.send(letter(key: "key-1")))
    XCTAssertEqual(fake.messages.count, 1, "the server has it; the phone does not know")

    // So it is queued under the same key, and the retry gets the first attempt's letter back.
    try outbox.queue(prisonerName: "Jane Smith", writingAs: nil, letter: letter(key: "key-1"), attachments: [try staged()])
    let outcome = await outbox.flush()
    XCTAssertEqual(outcome.sent, 1)
    XCTAssertEqual(fake.messages.count, 1, "the prisoner must never get the same letter twice")
    XCTAssertEqual(app.requests(to: "/messaging/message", method: "POST").map { $0.headers["Idempotency-Key"] }, ["key-1", "key-1"])
    XCTAssertEqual(fake.attachments.count, 1, "and the file went with the letter that already existed")
    XCTAssertEqual(fake.attachments.values.first?.meta["message"] as? Int, fake.messages[0]["id"] as? Int)
  }

  func testAFileWhoseUploadWasInterruptedGoesUpOnceAndTheLetterIsNotPostedAgain() async throws {
    try outbox.queue(prisonerName: "Jane Smith", writingAs: nil, letter: letter(), attachments: [try staged("one.pdf"), try staged("two.pdf", bytes: Data([9, 9]))])
    // The first file arrives, its answer is lost.
    fake.loseAnswerTo = { $0.path == "/messaging/attachment" }
    let interrupted = await outbox.flush()
    XCTAssertEqual(interrupted, FlushOutcome(sent: 0, refused: 0, stillWaiting: 1))
    XCTAssertTrue(try XCTUnwrap(outbox.items.first).letterWasSent)

    let resumed = await outbox.flush()
    XCTAssertEqual(resumed.sent, 1)
    XCTAssertEqual(app.requests(to: "/messaging/message", method: "POST").count, 1, "the letter was recorded as sent and is not posted again")
    XCTAssertEqual(fake.attachments.values.map { $0.meta["originalName"] as? String }.sorted { ($0 ?? "") < ($1 ?? "") }, ["one.pdf", "two.pdf"])
    let uploads = app.requests(to: "/messaging/attachment", method: "POST").map { $0.headers["Idempotency-Key"] }
    XCTAssertEqual(uploads.count, 3); XCTAssertEqual(uploads[0], uploads[1], "the retried upload repeats its key"); XCTAssertNotEqual(uploads[1], uploads[2])
  }

  func testARefusalKeepsTheLetterWithTheServersReasonAndCanBeTriedAgainAsItIs() async throws {
    try outbox.queue(prisonerName: "Jane Smith", writingAs: nil, letter: letter(), attachments: [])
    try outbox.queue(prisonerName: "Alex Johnson", writingAs: nil, letter: letter("A second letter."), attachments: [])
    fake.intercept = { $0.path == "/messaging/message" ? .error(403, info: "Your group is suspended; letters cannot be sent until an admin reinstates it.") : nil }
    let outcome = await outbox.flush()
    XCTAssertEqual(outcome, FlushOutcome(sent: 1, refused: 1, stillWaiting: 0), "a refused letter does not hold up the one behind it")
    let refused = try XCTUnwrap(outbox.items.first)
    XCTAssertEqual(refused.problem, "Your group is suspended; letters cannot be sent until an admin reinstates it.")
    XCTAssertFalse(outbox.hasWaiting)

    let ignored = await outbox.flush()
    XCTAssertEqual(ignored.sent, 0, "a refused letter waits for the writer, not for the network")
    outbox.retry(refused.id)
    let retried = await outbox.flush()
    XCTAssertEqual(retried.sent, 1)
    XCTAssertEqual(fake.messages.count, 2)
  }

  func testNoAnswerA5xxAndAWifiLoginPageAllMeanLaterAndStopTheRun() async throws {
    try outbox.queue(prisonerName: "Jane Smith", writingAs: nil, letter: letter(), attachments: [])
    try outbox.queue(prisonerName: "Alex Johnson", writingAs: nil, letter: letter("A second letter."), attachments: [])
    for answer in [Stubbed.error(503, info: "Down for maintenance."), .text("<html>Accept the terms to continue.</html>"), .error(429, info: "Slow down.")] {
      fake.intercept = { $0.path == "/messaging/message" ? answer : nil }
      let outcome = await outbox.flush()
      XCTAssertEqual(outcome, FlushOutcome(sent: 0, refused: 0, stillWaiting: 2))
    }
    XCTAssertEqual(app.requests(to: "/messaging/message", method: "POST").count, 3, "no point trying the next letter through the same broken connection")
    XCTAssertEqual(OutboxRepository.refusal(.conflict("Still working on it.", name: "IdempotencyError")), nil)
    XCTAssertEqual(OutboxRepository.refusal(.lettersLocked), nil, "a locked key waits for the password")
    XCTAssertEqual(OutboxRepository.refusal(.conflict("That group rotated its key.", name: "KeyVersionError")), "That group rotated its key.")
  }

  func testALetterSentEarlierAndDeletedSinceIsDroppedNotSentAgain() async throws {
    fake.loseAnswerTo = { $0.path == "/messaging/message" }
    await assertThrowsAppError(try await app.container.letters.send(letter(key: "key-2")))
    try outbox.queue(prisonerName: "Jane Smith", writingAs: nil, letter: letter(key: "key-2"), attachments: [])
    try await app.container.letters.delete(messageId: try XCTUnwrap(fake.messages[0]["id"] as? Int)) // withdrawn from another device
    let outcome = await outbox.flush()
    XCTAssertEqual(outcome, FlushOutcome(sent: 0, refused: 0, stillWaiting: 0))
    XCTAssertEqual(outbox.items, []); XCTAssertEqual(fake.messages.count, 0)
  }

  func testAQueuedLetterCanBeOpenedForEditingWithItsFilesAndDeleted() async throws {
    let id = try outbox.queue(prisonerName: "Jane Smith", writingAs: nil, letter: letter(), attachments: [try staged()])
    let opened = try XCTUnwrap(outbox.open(id))
    XCTAssertEqual(opened.payload.body, "Dear Jane, written in the basement."); XCTAssertEqual(opened.payload.relayNote, "two pages")
    XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(opened.files.first).url), Data([1, 2, 3, 4]))
    XCTAssertEqual(opened.files.first?.name, "scan.pdf")
    outbox.delete(id)
    XCTAssertEqual(outbox.items, [])
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outboxFolder.path), [])
  }

  func testLettersBelongToTheAccountThatWroteThemAndSurviveSignOutAndARelaunch() async throws {
    fake.noSignal = true
    try outbox.queue(prisonerName: "Jane Smith", writingAs: nil, letter: letter(), attachments: [])
    fake.noSignal = false
    try await app.container.sessions.logout()
    XCTAssertEqual(outbox.items, [], "signed out, nothing is shown")
    let signedOut = await outbox.flush()
    XCTAssertEqual(signedOut.sent, 0)

    // Someone else on the same phone neither sees nor sends it.
    try await app.container.sessions.login(username: "user2", password: "password2")
    outbox.reload()
    XCTAssertEqual(outbox.items, [])
    let asSomeoneElse = await outbox.flush()
    XCTAssertEqual(asSomeoneElse.sent, 0); XCTAssertEqual(fake.messages.count, 0)
    try await app.container.sessions.logout()

    // The writer comes back after a relaunch: same Keychain, same files.
    let fake = fake!
    let relaunched = TestApp(secrets: app.secrets, scratch: app.scratch) { fake.handle($0) }
    try await relaunched.container.sessions.login(username: "user1", password: "password1")
    relaunched.container.outbox.reload()
    XCTAssertEqual(relaunched.container.outbox.items.count, 1)
    let outcome = await relaunched.container.outbox.flush()
    XCTAssertEqual(outcome.sent, 1)
    XCTAssertEqual(fake.messages.first?["user"] as? Int, 4)
  }

  func testInEndToEndModeTheLetterIsSealedWhenItIsSentNotWhenItIsWritten() async throws {
    try await app.container.sessions.logout()
    fake.mode = "e2e"
    fake.groupKeys[2] = (Sodium.toBase64(relayGroup.publicKey), 4)
    await app.container.modes.refresh()
    try await app.container.sessions.login(username: "user1", password: "password1")

    fake.noSignal = true // the relay group's public key cannot be fetched, so nothing can be sealed yet
    let e2eLetter = NewLetter(prisonerId: 3, body: "Dear Jane, sealed later.", relayNote: nil, relayChapter: 2, idempotencyKey: "key-3")
    await assertThrowsAppError(try await app.container.letters.send(e2eLetter)) { XCTAssertTrue($0.meansNotReachingOurServer) }
    try outbox.queue(prisonerName: "Jane Smith", writingAs: nil, letter: e2eLetter, attachments: [try staged()])

    fake.noSignal = false
    let outcome = await outbox.flush()
    XCTAssertEqual(outcome.sent, 1)
    let stored = try XCTUnwrap(fake.messages.first)
    XCTAssertNil(stored["messageText"])
    let envelopes = try XCTUnwrap(stored["envelopes"] as? [[String: Any]])
    let key = try LetterCipher.openEnvelope(try XCTUnwrap(envelopes.last?["wrappedKey"] as? String), keyPair: relayGroup)
    XCTAssertEqual(try LetterCipher.decryptText(ciphertext: stored["ciphertext"] as! String, nonce: stored["nonce"] as! String, contentKey: key), "Dear Jane, sealed later.")
    // The file too: ciphertext on the server, under the letter's key.
    let file = try XCTUnwrap(fake.attachments.values.first)
    XCTAssertEqual(try LetterCipher.decryptFile(file.bytes, nonce: try XCTUnwrap(file.meta["nonce"] as? String), contentKey: key), Data([1, 2, 3, 4]))
  }

  func testAKeyReusedForADifferentLetterIsARefusalNotARetryLoop() async throws {
    _ = try await app.container.letters.send(letter(key: "key-4"))
    try outbox.queue(prisonerName: "Jane Smith", writingAs: nil, letter: letter("Different words under the same key.", key: "key-4"), attachments: [])
    let outcome = await outbox.flush()
    XCTAssertEqual(outcome.refused, 1)
    XCTAssertEqual(outbox.items.first?.problem, "This Idempotency-Key was used for a different request.")
  }

  func testOurOwnAttemptStillRunningIsWaitedForNotMistakenForAKeyRotation() async throws {
    fake.intercept = { $0.path == "/messaging/message" ? .error(409, info: "Error sending.", extra: ["name": "IdempotencyError", "error": "Still processing."]).with(["Retry-After": "1"]) : nil }
    let sent = try await app.container.letters.send(letter(key: "key-5"))
    XCTAssertEqual(sent.body, "Dear Jane, written in the basement.")
    XCTAssertEqual(app.requests(to: "/messaging/message", method: "POST").count, 2)
  }
}

private extension Stubbed {
  func with(_ headers: [String: String]) -> Stubbed { var s = self; s.headers = headers; return s }
}
