@testable import ABCCore
import XCTest

/// Returned mail (API PR #105) and letters held because their prisoner was moved or freed (API PR #106),
/// from both sides: the group member holding the envelope, and the writer who is told.
@MainActor
final class ReturnedAndHeldTests: XCTestCase {
  private var fake: FakeAPI!
  private var writer: TestApp!
  private var member: TestApp!

  override func setUp() async throws {
    fake = FakeAPI()
    fake.mode = "server"
    fake.accounts = [
      FakeAPI.Account(id: 9, username: "member1", password: "password1", role: "chapter", chapterId: 1, name: "Sam"),
      FakeAPI.Account(id: 4, username: "user1", password: "password1"),
      FakeAPI.Account(id: 5, username: "user2", password: "password2"),
    ]
    let fake = fake!
    writer = TestApp { fake.handle($0) }
    member = TestApp { fake.handle($0) }
    try await writer.container.sessions.login(username: "user1", password: "password1")
    try await member.container.sessions.login(username: "member1", password: "password1")
  }

  private func mailed(_ body: String = "Dear friend") async throws -> Letter {
    let sent = try await writer.container.letters.send(NewLetter(prisonerId: 3, body: body, relayNote: nil, relayChapter: 1))
    _ = try await member.container.group.setStatus(messageId: sent.id, status: .printed)
    return try await member.container.group.setStatus(messageId: sent.id, status: .mailed)
  }

  func testAGroupRecordsAReturnWithItsReasonAndTheWriterIsToldAndCanSendItAgainOnce() async throws {
    let letter = try await mailed()
    // An ordinary move says nothing about reasons or releases: the API refuses a reason on any move but a return.
    XCTAssertEqual(try XCTUnwrap(member.requests(to: "/messaging/status", method: "PUT").first).json as NSDictionary, ["id": letter.id, "status": "printed"])

    let back = try await member.container.group.markReturned(messageId: letter.id, reason: .transferred, note: "  Stamped NOT HERE ")
    XCTAssertEqual(try XCTUnwrap(member.requests(to: "/messaging/status", method: "PUT").last).json as NSDictionary, ["id": letter.id, "status": "returned", "reason": "transferred", "note": "Stamped NOT HERE"])
    XCTAssertEqual(back.status, .returned); XCTAssertEqual(back.returnReason, .transferred); XCTAssertEqual(back.returnNote, "Stamped NOT HERE")
    let returnedList = try await member.container.group.queue(groupId: 1, status: .returned, page: 1, pageSize: 20)
    XCTAssertEqual(returnedList.items.map(\.id), [letter.id])

    let news = await writer.container.activity.sync()
    XCTAssertEqual(news.map(\.kind), [.returned, .mailed, .printed])
    XCTAssertEqual(news.first?.sentence, "One of your letters came back in the mail.", "why is inside the app, not on a lock screen")

    let mine = try await writer.container.letters.letter(messageId: letter.id)
    XCTAssertTrue(mine.canSendAgain); XCTAssertFalse(mine.canEdit); XCTAssertTrue(try XCTUnwrap(mine.returnReason).doubtsTheAddress)

    // The server keeps no copy to send again: the text travels again, with the link.
    let again = try await writer.container.letters.send(NewLetter(prisonerId: 3, body: mine.body, relayNote: nil, relayChapter: nil, resendOf: mine.id))
    XCTAssertEqual(try XCTUnwrap(writer.requests(to: "/messaging/message", method: "POST").last).json as NSDictionary, ["messageText": "Dear friend", "prisoner": 3, "sender": "user", "resendOf": letter.id])
    XCTAssertEqual(again.resendOf, letter.id); XCTAssertEqual(again.status, .queued)
    let afterwards = try await writer.container.letters.letter(messageId: letter.id)
    XCTAssertEqual(afterwards.resentAs.map(\.id), [again.id]); XCTAssertFalse(afterwards.canSendAgain)

    // The conversation screen reads the thread. Since API PR #117 the note is on the letter itself, so no letter is
    // read by itself for it; `resent_as` is still rebuilt from the sibling letters' `resendOf`.
    let reads = writer.requests(to: "/messaging/message", method: "GET").count
    let thread = try await writer.container.letters.thread(chatId: 3)
    let inThread = try XCTUnwrap(thread.letters.first { $0.id == letter.id })
    XCTAssertEqual(inThread.returnNote, "Stamped NOT HERE"); XCTAssertEqual(inThread.resentAs.map(\.id), [again.id]); XCTAssertFalse(inThread.canSendAgain)
    XCTAssertEqual(writer.requests(to: "/messaging/message", method: "GET").count, reads, "the note came with the conversation")
    // An older API sends no returnNote: then, and only then, the letter is read by itself.
    let old = try JSONDecoder().decode(MessageDTO.self, from: Data(#"{"id":41,"sender":"user","prisoner":3,"status":"returned","returnReason":"refused"}"#.utf8)).toDomain()
    XCTAssertNil(old.returnNote)
  }

  func testOnlyAReturnedLetterOfOnesOwnCanBeSentAgain() async throws {
    let letter = try await mailed()
    await assertThrowsAppError(try await writer.container.letters.send(NewLetter(prisonerId: 3, body: "Again", relayNote: nil, relayChapter: nil, resendOf: letter.id))) { XCTAssertEqual($0.userMessage, "resendOf must be one of this writer's returned letters to the same prisoner.") }
    XCTAssertFalse(letter.canSendAgain)
  }

  func testAReturnNoteOverTheLimitNeverLeavesThePhoneAndAnEmptyOneIsNotSent() async throws {
    let letter = try await mailed()
    let before = member.requests(to: "/messaging/status", method: "PUT").count
    await assertThrowsAppError(try await member.container.group.markReturned(messageId: letter.id, reason: .refused, note: String(repeating: "x", count: 201))) { XCTAssertEqual($0.userMessage, "The note can be at most 200 characters.") }
    XCTAssertEqual(member.requests(to: "/messaging/status", method: "PUT").count, before)

    _ = try await member.container.group.markReturned(messageId: letter.id, reason: .refused, note: "   ")
    XCTAssertEqual(try XCTUnwrap(member.requests(to: "/messaging/status", method: "PUT").last).json as NSDictionary, ["id": letter.id, "status": "returned", "reason": "refused"])
  }

  func testALetterToSomeoneWhoWasFreedIsHeldAndPrintedOnlyOnPurpose() async throws {
    let sent = try await writer.container.letters.send(NewLetter(prisonerId: 3, body: "Dear friend", relayNote: nil, relayChapter: 1))
    fake.directoryLearns(prisoner: 3, event: "prisoner.status", holding: "prisoner_free")

    let news = await writer.container.activity.sync()
    XCTAssertEqual(news.map(\.kind), [.freed(held: 1)])
    XCTAssertEqual(news.first?.sentence, "Someone you write to has been released. A letter you wrote them is waiting for you.")
    let mine = try await writer.container.letters.letter(messageId: sent.id)
    XCTAssertEqual(mine.statusLabel, "On hold", "not Queued: nobody is going to print it as things stand")
    // The conversation list says so on the row (API PR #117), and which side it waits on.
    let rows = try await writer.container.letters.threads(page: 1, pageSize: 20)
    let row = try XCTUnwrap(rows.items.first { $0.prisonerId == 3 })
    XCTAssertEqual(row.heldCount, 1); XCTAssertEqual(row.heldReasons, [.prisonerFree]); XCTAssertFalse(row.waitsOnWriter, "freed waits on the group")
    let full = try await writer.container.letters.thread(chatId: 3)
    XCTAssertEqual(full.heldCount, 1)
    XCTAssertEqual(mine.heldReason, .prisonerFree); XCTAssertTrue(mine.isHeld); XCTAssertTrue(mine.canEdit, "held is not a status: the letter is still queued, and still the writer's to withdraw")

    let group = member.container.group
    let held = try await group.held(groupId: 1, page: 1, pageSize: 20)
    XCTAssertEqual(held.items.map(\.id), [sent.id])
    await assertThrowsAppError(try await group.setStatus(messageId: sent.id, status: .printed)) { XCTAssertTrue($0.isLetterHeld) }
    let queued = try await writer.container.letters.letter(messageId: sent.id)
    XCTAssertEqual(queued.status, .queued)

    let printed = try await group.setStatus(messageId: sent.id, status: .printed, release: true)
    XCTAssertEqual(try XCTUnwrap(member.requests(to: "/messaging/status", method: "PUT").last).json as NSDictionary, ["id": sent.id, "status": "printed", "release": true])
    XCTAssertEqual(printed.status, .printed); XCTAssertNil(printed.heldReason); XCTAssertFalse(printed.isHeld); XCTAssertEqual(printed.statusLabel, "Printed")
  }

  func testAnAPIFromBeforeHeldLettersAnswersWithEverythingAndNoneOfItIsShownAsHeld() async throws {
    // Seen on the simulator against a development server one pull request behind: the Held filter listed every letter.
    fake.predatesHeldLetters = true
    _ = try await mailed()
    _ = try await writer.container.letters.send(NewLetter(prisonerId: 3, body: "Queued, and not held", relayNote: nil, relayChapter: 1))
    let held = try await member.container.group.held(groupId: 1, page: 1, pageSize: 20)
    XCTAssertEqual(held.items.map(\.id), []); XCTAssertEqual(held.total, 0)
  }

  func testAfterAMoveTheWriterChoosesWhoMailsItAndOnlyThatIsSent() async throws {
    let sent = try await writer.container.letters.send(NewLetter(prisonerId: 3, body: "Dear friend", relayNote: "two pages", relayChapter: 1))
    fake.directoryLearns(prisoner: 3, event: "prisoner.moved", holding: "choose_relay")
    let news = await writer.container.activity.sync()
    XCTAssertEqual(news.map(\.kind), [.moved(held: 1)])
    let rows = try await writer.container.letters.threads(page: 1, pageSize: 20)
    XCTAssertTrue(try XCTUnwrap(rows.items.first { $0.prisonerId == 3 }).waitsOnWriter, "choose_relay waits on the writer")

    try await writer.container.letters.chooseRelay(messageId: sent.id, groupId: 2)
    XCTAssertEqual(try XCTUnwrap(writer.requests(to: "/messaging/message", method: "PUT").last).json as NSDictionary, ["id": sent.id, "relayChapter": 2])
    let mine = try await writer.container.letters.letter(messageId: sent.id)
    XCTAssertNil(mine.heldReason); XCTAssertEqual(mine.relayGroupId, 2); XCTAssertEqual(mine.body, "Dear friend"); XCTAssertEqual(mine.relayNote, "two pages")
  }

  func testSomeoneWithNoLetterWaitingIsToldOfTheMoveAndNothingMore() async throws {
    _ = try await mailed()
    fake.directoryLearns(prisoner: 3, event: "prisoner.moved", holding: "choose_relay")
    let news = await writer.container.activity.sync()
    XCTAssertEqual(news.first?.kind, .moved(held: 0))
    XCTAssertEqual(news.first?.sentence, "Someone you write to was moved to another facility.")
    XCTAssertEqual(Activity(id: 1, kind: .moved(held: 3), chatId: nil, messageId: nil).sentence, "Someone you write to was moved to another facility. 3 letters you wrote them are waiting for you.")
  }

  func testCodesThisVersionHasNeverHeardOfStillMeanSomething() throws {
    XCTAssertEqual(LetterStatus.from(key: "returned"), .returned)
    XCTAssertEqual(ReturnReason.from(key: "eaten_by_dog"), .unknown); XCTAssertNil(ReturnReason.from(key: nil)); XCTAssertNil(ReturnReason.from(key: ""))
    XCTAssertEqual(HeldReason.from(key: "quarantined"), .other, "a hold with a new reason is still a hold"); XCTAssertNil(HeldReason.from(key: nil))
    XCTAssertEqual(Set(ReturnReason.allCases.map(\.advice)).count, 6, "every reason has advice of its own")
    XCTAssertEqual(Set(ReturnReason.allCases.map(\.key)), ["refused", "rule_violation", "transferred", "released", "bad_address", "unknown"])
    XCTAssertEqual(Activity.kind(event: "prisoner.status", status: "deceased"), .other)

    let dto = try JSONDecoder().decode(MessageDTO.self, from: Data(#"{"id":41,"sender":"user","prisoner":3,"status":"queued","heldReason":"quarantined","resent_as":[]}"#.utf8))
    XCTAssertTrue(dto.toDomain().isHeld)
    // A letter from before either pull request has none of the new fields.
    let old = try JSONDecoder().decode(MessageDTO.self, from: Data(#"{"id":41,"sender":"user","prisoner":3,"status":"mailed","status_history":[{"fromStatus":"printed","toStatus":"mailed","changedBy":9,"createdAt":"2026-09-19T10:00:00.000Z"}]}"#.utf8)).toDomain()
    XCTAssertNil(old.returnReason); XCTAssertNil(old.heldReason); XCTAssertNil(old.returnNote); XCTAssertEqual(old.resentAs, [])
  }

  func testALetterQueuedOfflineBeforeThisVersionStillOpensAndAResendKeepsItsLinkInTheOutbox() throws {
    let old = #"{"prisonerId":3,"prisonerName":"Jane","body":"Hi","fromPrisoner":false,"groupRelaysFacility":false,"attachments":[],"idempotencyKey":"k"}"#
    XCTAssertNil(try JSONDecoder().decode(OutboxPayload.self, from: Data(old.utf8)).resendOf)

    let id = try writer.container.outbox.queue(prisonerName: "Jane", writingAs: nil, letter: NewLetter(prisonerId: 3, body: "Again", relayNote: nil, relayChapter: nil, resendOf: 41), attachments: [])
    XCTAssertEqual(writer.container.outbox.open(id)?.payload.newLetter.resendOf, 41)
  }
}
