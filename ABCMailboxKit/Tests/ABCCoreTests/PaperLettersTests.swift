@testable import ABCCore
import ABCCrypto
import XCTest

/// Paper letters (API PR #118): a letter written by hand and handed to the relay group, logged so that a reply has
/// a thread to come back to. Against the fake API in end-to-end mode, with real sealed boxes.
@MainActor
final class PaperLettersTests: XCTestCase {
  private var fake: FakeAPI!
  private var writer: TestApp!
  private var member: TestApp!
  private let relayGroup = Sodium.keypair()

  override func setUp() async throws {
    fake = FakeAPI()
    fake.mode = "e2e"
    fake.accounts = [
      FakeAPI.Account(id: 9, username: "member1", password: "password1", role: "chapter", chapterId: 1, name: "Sam"),
      FakeAPI.Account(id: 4, username: "user1", password: "password1"),
    ]
    let fake = fake!
    writer = TestApp { fake.handle($0) }
    member = TestApp { fake.handle($0) }
    try await member.container.sessions.login(username: "member1", password: "password1")
    member.container.sessions.recoveryCodeSaved()
    _ = await member.container.group.setUpKeys()
    try await writer.container.sessions.login(username: "user1", password: "password1")
    writer.container.sessions.recoveryCodeSaved()
  }

  func testAPaperLetterIsLoggedWithNoTextStartsPrintedAndItsPhotoMayFollowUntilItIsMailed() async throws {
    let logged = try await writer.container.letters.send(NewLetter(prisonerId: 3, body: "", relayNote: nil, relayChapter: 1, paper: true))
    let sent = try XCTUnwrap(writer.requests(to: "/messaging/message", method: "POST").first).json
    XCTAssertEqual(sent["paper"] as? Bool, true); XCTAssertNil(sent["messageText"])
    XCTAssertNotNil(sent["ciphertext"], "end-to-end: an empty string is sealed all the same, because that content key is what the photo is encrypted with")
    XCTAssertEqual((sent["envelopes"] as? [[String: Any]])?.count, 2)
    XCTAssertTrue(logged.paper); XCTAssertEqual(logged.status, .printed); XCTAssertEqual(logged.body, "")
    XCTAssertEqual(logged.history.map { "\($0.from.map(\.key) ?? "nil")>\($0.to.key)" }, ["nil>printed"], "printed from birth")
    XCTAssertFalse(logged.canEdit, "printed: not the writer's to edit or delete"); XCTAssertTrue(logged.canAttach, "but the photo may follow")
    XCTAssertEqual(logged.statusLabel, "On paper")

    // The photo, added later, encrypted with the letter's key; the group opens it.
    let page = Data(repeating: 7, count: 300)
    let staged = try writer.container.files.stage(data: page, name: "page.jpg", mimeType: "image/jpeg")
    let photo = try await writer.container.letters.upload(messageId: logged.id, staged: staged)
    XCTAssertNotNil(photo.nonce, "encrypted")
    let theirs = try await member.container.group.queueItem(messageId: logged.id)
    XCTAssertEqual(theirs.letter.attachments.count, 1); XCTAssertTrue(theirs.letter.paper)
    let opened = try await member.container.letters.download(theirs.letter.attachments[0])
    XCTAssertEqual(try Data(contentsOf: opened), page)

    // Never under queued; under printed, on paper, nothing to print. Mailed with the batch, after which the photo is fixed.
    let queued = try await member.container.group.queue(groupId: 1, status: .queued, page: 1, pageSize: 20)
    XCTAssertFalse(queued.items.contains { $0.id == logged.id })
    let printed = try await member.container.group.queue(groupId: 1, status: .printed, page: 1, pageSize: 20)
    XCTAssertEqual(printed.items.first { $0.id == logged.id }?.letter.paper, true)
    let moved = try await member.container.group.setStatusOfMany(messageIds: [logged.id], status: .mailed)
    XCTAssertEqual(moved, 1)
    let mailed = try await writer.container.letters.letter(messageId: logged.id)
    XCTAssertEqual(mailed.status, .mailed); XCTAssertFalse(mailed.canAttach); XCTAssertEqual(mailed.statusLabel, "Mailed")
  }

  func testTheGroupIsToldOfAPaperLetterInWordsThatSayNothingToPrint() async throws {
    _ = try await writer.container.letters.send(NewLetter(prisonerId: 3, body: "", relayNote: nil, relayChapter: 1, paper: true))
    _ = try await writer.container.letters.send(NewLetter(prisonerId: 3, body: "Typed.", relayNote: nil, relayChapter: 1))
    let news = await member.container.activity.sync()
    XCTAssertEqual(news.count, 2); XCTAssertTrue(news.contains { $0.kind == .paperForGroup }); XCTAssertTrue(news.contains { $0.kind == .queuedForGroup })
    XCTAssertEqual(news.first { $0.kind == .paperForGroup }?.sentence, "A paper letter is waiting to go out with your group's next batch.")
    XCTAssertEqual(Activity.kind(event: "letter.queued", status: nil, paper: false), .queuedForGroup)
  }

  func testAReplyIsNeverOnPaperAndATypedAndAPaperLetterUnderOneKeyAreTwoRequests() async throws {
    // The codec drops the flag for a reply rather than let the server refuse it.
    _ = try await member.container.letters.send(NewLetter(prisonerId: 3, body: "From inside.", relayNote: nil, relayChapter: nil, asWriterId: 4, fromPrisoner: true, paper: true))
    let reply = try XCTUnwrap(member.requests(to: "/messaging/message", method: "POST").last).json
    XCTAssertNil(reply["paper"])
    // The Idempotency-Key fingerprint includes paper (the fake mirrors the API): the same key for the other kind is refused, not replayed.
    let key = UUID().uuidString
    let typed = try await writer.container.letters.send(NewLetter(prisonerId: 3, body: "Same key", relayNote: nil, relayChapter: 1, idempotencyKey: key))
    await assertThrowsAppError(try await writer.container.letters.send(NewLetter(prisonerId: 3, body: "Same key", relayNote: nil, relayChapter: 1, idempotencyKey: key, paper: true))) { XCTAssertTrue($0.isConflict || $0.userMessage?.contains("Idempotency") == true) }
    XCTAssertEqual(typed.status, .queued)
    // A paper letter with nobody to mail it is refused by the server with a sentence.
    await assertThrowsAppError(try await writer.container.letters.send(NewLetter(prisonerId: 3, body: "", relayNote: nil, relayChapter: nil, paper: true))) { XCTAssertEqual($0.userMessage, "A paper letter needs a relay group to mail it: send relayChapter.") }
  }

  func testALetterQueuedOfflineBeforePaperExistedStillOpensAndAPaperOneKeepsItsFlag() throws {
    let old = #"{"prisonerId":3,"prisonerName":"Jane","body":"Hi","fromPrisoner":false,"groupRelaysFacility":false,"attachments":[],"idempotencyKey":"k"}"#
    XCTAssertFalse(try JSONDecoder().decode(OutboxPayload.self, from: Data(old.utf8)).newLetter.paper)
    let id = try writer.container.outbox.queue(prisonerName: "Jane", writingAs: nil, letter: NewLetter(prisonerId: 3, body: "", relayNote: nil, relayChapter: 1, paper: true), attachments: [])
    XCTAssertTrue(try XCTUnwrap(writer.container.outbox.open(id)).payload.newLetter.paper)
    // A letter from before either pull request has no paper field.
    let dto = try JSONDecoder().decode(MessageDTO.self, from: Data(#"{"id":41,"sender":"user","prisoner":3,"status":"printed"}"#.utf8)).toDomain()
    XCTAssertFalse(dto.paper); XCTAssertFalse(dto.canAttach); XCTAssertEqual(dto.statusLabel, "Printed")
  }
}
