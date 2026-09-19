@testable import ABCCore
import ABCCrypto
import XCTest

/// Letters end to end against the fake API: what is sent is really ciphertext, and what is read was really opened.
@MainActor
final class LettersFlowTests: XCTestCase {
  private var fake: FakeAPI!
  private var app: TestApp!
  private var letters: LettersRepository { app.container.letters }
  private let relayGroup = Sodium.keypair()

  override func setUp() async throws {
    fake = FakeAPI()
    fake.accounts = [FakeAPI.Account(id: 4, username: "user1", password: "password1")]
    fake.groupKeys[2] = (Sodium.toBase64(relayGroup.publicKey), 4)
    let fake = fake!
    app = TestApp { fake.handle($0) }
  }

  private func signIn() async throws { try await app.container.sessions.login(username: "user1", password: "password1") }

  func testServerModePassesPlainTextThroughAndNeedsNoKeys() async throws {
    fake.mode = "server"
    try await signIn()
    let sent = try await letters.send(NewLetter(prisonerId: 3, body: "Dear friend", relayNote: "two pages", relayChapter: 2))
    XCTAssertEqual(sent.body, "Dear friend")
    XCTAssertEqual(try XCTUnwrap(app.requests(to: "/messaging/message", method: "POST").first).json as NSDictionary, ["messageText": "Dear friend", "prisoner": 3, "sender": "user", "relayChapter": 2, "relayNote": "two pages"])
    XCTAssertEqual(app.requests(to: "/auth/public-key").count, 0)
  }

  func testEndToEndSealsToTheWriterAndToTheRelayGroupWithItsKeyVersionAndNoPlaintextLeavesThePhone() async throws {
    try await signIn()
    let body = "Dear friend, the tomatoes are in. Ünïcödé too."
    let sent = try await letters.send(NewLetter(prisonerId: 3, body: body, relayNote: "two pages", relayChapter: 2))
    XCTAssertEqual(sent.body, body); XCTAssertEqual(sent.relayNote, "two pages"); XCTAssertFalse(sent.locked)

    let request = try XCTUnwrap(app.requests(to: "/messaging/message", method: "POST").first)
    XCTAssertNil(request.json["messageText"], "plaintext must never be sent"); XCTAssertNil(request.json["relayNote"])
    XCTAssertFalse(request.bodyText.contains("tomatoes")); XCTAssertFalse(request.bodyText.contains("two pages"))
    let envelopes = try XCTUnwrap(request.json["envelopes"] as? [[String: Any]])
    XCTAssertEqual(envelopes.map { "\($0["readerType"]!) \($0["readerId"]!) v\($0["keyVersion"] ?? "-")" }, ["user 4 v-", "chapter 2 v4"])

    // The relay group, holding only its own key, reads the letter and the note.
    let key = try LetterCipher.openEnvelope(envelopes[1]["wrappedKey"] as! String, keyPair: relayGroup)
    XCTAssertEqual(try LetterCipher.decryptText(ciphertext: request.json["ciphertext"] as! String, nonce: request.json["nonce"] as! String, contentKey: key), body)
    XCTAssertEqual(try LetterCipher.decryptText(ciphertext: request.json["relayNoteCiphertext"] as! String, nonce: request.json["relayNoteNonce"] as! String, contentKey: key), "two pages")
  }

  func testARelayGroupWithoutKeysCannotBeWrittenToAndSaysSo() async throws {
    try await signIn()
    await assertThrowsAppError(try await letters.send(NewLetter(prisonerId: 3, body: "Dear friend", relayNote: nil, relayChapter: 9))) {
      guard case .validation(let errors) = $0 else { return XCTFail("expected validation") }
      XCTAssertTrue(errors[0].contains("has not set up encryption"))
    }
    XCTAssertEqual(app.requests(to: "/messaging/message").count, 0)
  }

  func testALockedVaultRefusesToSendRatherThanSendingSomethingUnreadable() async throws {
    try await signIn()
    app.container.vault.clear()
    await assertThrowsAppError(try await letters.send(NewLetter(prisonerId: 3, body: "Dear friend", relayNote: nil, relayChapter: nil))) { XCTAssertEqual($0, .lettersLocked) }
  }

  func testLettersStayLockedWithoutAKeyThatOpensThem() async throws {
    try await signIn()
    let sent = try await letters.send(NewLetter(prisonerId: 3, body: "Dear friend", relayNote: nil, relayChapter: nil))
    app.container.vault.clear()
    let reread = try await letters.letter(messageId: sent.id)
    XCTAssertTrue(reread.locked); XCTAssertEqual(reread.body, "")
  }

  func testAnEditReencryptsUnderTheExistingKeyAndDoesNotTouchTheReaders() async throws {
    try await signIn()
    let sent = try await letters.send(NewLetter(prisonerId: 3, body: "first draft", relayNote: "a note", relayChapter: 2))
    try await letters.edit(LetterEdit(messageId: sent.id, body: "second draft", relayNote: nil, relayChapter: 2))
    let put = try XCTUnwrap(app.requests(to: "/messaging/message", method: "PUT").first)
    XCTAssertEqual(Set(put.json.keys), ["id", "ciphertext", "nonce"], "no plaintext, no relay group, no envelopes")
    let reread = try await letters.letter(messageId: sent.id)
    XCTAssertEqual(reread.body, "second draft"); XCTAssertNil(reread.relayNote)
  }

  func testAKeyRotationBetweenLookupAndSendIsRetriedOnceWithTheNewKey() async throws {
    try await signIn()
    let rotated = Sodium.keypair()
    let fake = fake!
    fake.intercept = { r in
      guard r.method == "POST", r.path == "/messaging/message" else { return nil }
      fake.groupKeys[2] = (Sodium.toBase64(rotated.publicKey), 5) // the group rotated just before this arrived
      return .error(409, info: "Error sending.", extra: ["name": "KeyVersionError"])
    }
    let sent = try await letters.send(NewLetter(prisonerId: 3, body: "Dear friend", relayNote: nil, relayChapter: 2))
    XCTAssertEqual(sent.body, "Dear friend")
    let posts = app.requests(to: "/messaging/message", method: "POST")
    XCTAssertEqual(posts.count, 2)
    let envelope = try XCTUnwrap((posts[1].json["envelopes"] as? [[String: Any]])?.last)
    XCTAssertEqual(envelope["keyVersion"] as? Int, 5)
    XCTAssertNoThrow(try LetterCipher.openEnvelope(envelope["wrappedKey"] as! String, keyPair: rotated))
  }

  func testAnAttachmentIsEncryptedUnderTheLettersKeyAndComesBackAsTheSameBytes() async throws {
    try await signIn()
    let sent = try await letters.send(NewLetter(prisonerId: 3, body: "See the scan.", relayNote: nil, relayChapter: nil))
    let plain = Sodium.randomBytes(50_000)
    let staged = try app.container.files.stage(data: plain, name: "scan.pdf", mimeType: "application/pdf")
    let attachment = try await letters.upload(messageId: sent.id, staged: staged)
    XCTAssertNotNil(attachment.nonce)
    let stored = try XCTUnwrap(fake.attachments[attachment.id]?.bytes)
    XCTAssertEqual(stored.count, plain.count + 16); XCTAssertNotEqual(stored.prefix(64), plain.prefix(64))

    let file = try await letters.download(attachment)
    XCTAssertEqual(try Data(contentsOf: file), plain)
    XCTAssertEqual(file.lastPathComponent, "scan.pdf")
    _ = try await letters.download(attachment)
    XCTAssertEqual(app.requests(to: "/messaging/attachment", method: "GET").count, 1, "the second open is served from the cache")
  }

  func testServerModeUploadsAndDownloadsTheBytesAsTheyAre() async throws {
    fake.mode = "server"
    try await signIn()
    let sent = try await letters.send(NewLetter(prisonerId: 3, body: "See the photo.", relayNote: nil, relayChapter: nil))
    let staged = try app.container.files.stage(data: Data([9, 8, 7]), name: "photo.jpg", mimeType: "image/jpeg")
    XCTAssertTrue(staged.isImage)
    let attachment = try await letters.upload(messageId: sent.id, staged: staged)
    XCTAssertNil(attachment.nonce)
    XCTAssertEqual(fake.attachments[attachment.id]?.bytes, Data([9, 8, 7]))
    let file = try await letters.download(attachment)
    XCTAssertEqual(try Data(contentsOf: file), Data([9, 8, 7]))
  }
}
