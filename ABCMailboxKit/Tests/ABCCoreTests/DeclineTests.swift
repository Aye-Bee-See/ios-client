@testable import ABCCore
import XCTest

/// API #170: a relay group declines to mail a letter, with a reason; the writer sees why and can send it again.
@MainActor
final class DeclineTests: XCTestCase {
  private var fake: FakeAPI!
  private var writer: TestApp!
  private var member: TestApp!
  private var group: GroupRepository { member.container.group }

  override func setUp() async throws {
    fake = FakeAPI()
    fake.mode = "server"
    fake.accounts = [
      FakeAPI.Account(id: 9, username: "member1", password: "password1", role: "chapter", chapterId: 1, name: "Sam"),
      FakeAPI.Account(id: 4, username: "user1", password: "password1"),
    ]
    let fake = fake!
    writer = TestApp { fake.handle($0) }
    member = TestApp { fake.handle($0) }
    try await writer.container.sessions.login(username: "user1", password: "password1")
    try await member.container.sessions.login(username: "member1", password: "password1")
  }

  private func queued(_ count: Int) async throws -> [Int] {
    var ids: [Int] = []
    for i in 1...count { ids.append(try await writer.container.letters.send(NewLetter(prisonerId: 3, body: "Letter \(i)", relayNote: nil, relayChapter: 1)).id) }
    return ids
  }

  func testDecliningForAFacilityRuleSendsTheTagAndTheWriterReadsWhyAndMaySendAgain() async throws {
    let id = try await queued(1)[0]
    let item = try await group.queueItem(messageId: id)
    XCTAssertEqual(item.prisoner?.facility?.rules.rules.map(\.tag), ["handwritten_only", "no_stickers"], "the rules the sheet offers")
    XCTAssertTrue(item.letter.canBeDeclined)

    let declined = try await group.decline(messageId: id, reason: .facilityRule, rule: "handwritten_only", note: "  This facility only takes handwritten letters.  ")
    XCTAssertEqual(declined.status, .declined); XCTAssertEqual(declined.statusLabel, "Not mailed")
    let sent = try XCTUnwrap(member.requests(to: "/messaging/status", method: "PUT").last).json
    XCTAssertEqual(sent as NSDictionary, ["id": id, "status": "declined", "reason": "facility_rule", "rule": "handwritten_only", "note": "This facility only takes handwritten letters."])

    let seen = try await writer.container.letters.letter(messageId: id)
    XCTAssertEqual(seen.declineReason, .facilityRule); XCTAssertEqual(seen.declineRule, "handwritten_only")
    XCTAssertEqual(seen.declineNote, "This facility only takes handwritten letters.")
    XCTAssertTrue(seen.canSendAgain); XCTAssertFalse(seen.canBeDeclined)
    XCTAssertEqual(seen.history.last?.declineReason, .facilityRule); XCTAssertNil(seen.history.last?.reason, "a decline's reason is not a return's")
    XCTAssertEqual(MailRuleCatalog.compiled.resolve("handwritten_only").label.isEmpty, false)

    // Sent again, the new letter names the declined one, exactly as after a return.
    let again = try await writer.container.letters.send(NewLetter(prisonerId: 3, body: "Letter 1, handwritten", relayNote: nil, relayChapter: 1, resendOf: id))
    XCTAssertEqual(writer.requests(to: "/messaging/message", method: "POST").last?.json["resendOf"] as? Int, id)
    XCTAssertEqual(again.status, .queued)
  }

  func testAReasonOtherThanARuleSendsNoRuleAndABlankNoteIsLeftOut() async throws {
    let id = try await queued(1)[0]
    _ = try await group.decline(messageId: id, reason: .content, rule: "handwritten_only", note: "   ")
    XCTAssertEqual(member.requests(to: "/messaging/status", method: "PUT").last?.json as NSDictionary?, ["id": id, "status": "declined", "reason": "content"])
  }

  func testANoteOverTheLimitIsRefusedOnThePhoneAndARuleTheFacilityLacksByTheServer() async throws {
    let id = try await queued(1)[0]
    await assertThrowsAppError(try await group.decline(messageId: id, reason: .other, rule: nil, note: String(repeating: "x", count: 201))) {
      XCTAssertEqual($0, .validation(["The note can be at most 200 characters."]))
    }
    XCTAssertEqual(member.requests(to: "/messaging/status", method: "PUT").count, 0)
    await assertThrowsAppError(try await group.decline(messageId: id, reason: .facilityRule, rule: "no_perfume", note: nil)) {
      XCTAssertEqual($0.fieldProblems.first?.field, "rule")
    }
  }

  func testSeveralAreDeclinedTogetherWithOneReasonAndOnlyTheRulesTheyShareAreOffered() async throws {
    let ids = try await queued(3)
    let declined = try await group.declineMany(messageIds: ids + [ids[0]], reason: .other, rule: "ignored", note: "Our group is not mailing to this facility for now.")
    XCTAssertEqual(declined, 3)
    let sent = try XCTUnwrap(member.requests(to: "/messaging/status/batch", method: "PUT").last).json
    XCTAssertEqual(sent["ids"] as? [Int], ids, "each letter once, in order"); XCTAssertNil(sent["rule"], "a rule goes with facility_rule only")
    for id in ids {
      let status = try await writer.container.letters.letter(messageId: id).status
      XCTAssertEqual(status, .declined)
    }

    let rules = { (tags: [String]) in MailRules(rules: tags.map { MailRuleCatalog.compiled.resolve($0) }) }
    XCTAssertEqual(MailRules.common([rules(["handwritten_only", "no_stickers"]), rules(["no_stickers", "no_perfume"])]).map(\.tag), ["no_stickers"])
    XCTAssertEqual(MailRules.common([rules(["handwritten_only"]), rules(["no_perfume"])]), [])
    XCTAssertEqual(MailRules.common([rules(["handwritten_only"]), MailRules()]), [], "a facility not known shares no rule")
  }

  func testTheWriterIsToldAndAMailedLetterCannotBeDeclined() async throws {
    let id = try await queued(1)[0]
    _ = try await group.decline(messageId: id, reason: .content, rule: nil, note: nil)
    let feed = await writer.container.activity.sync()
    XCTAssertEqual(feed.last?.kind, .declined)
    XCTAssertEqual(feed.last?.sentence, "Your group decided not to send one of your letters.")

    let mailed = try await queued(1)[0]
    _ = try await group.setStatus(messageId: mailed, status: .printed)
    _ = try await group.setStatus(messageId: mailed, status: .mailed)
    await assertThrowsAppError(try await group.decline(messageId: mailed, reason: .other, rule: nil, note: nil)) { XCTAssertTrue($0.isConflict) }
  }
}
