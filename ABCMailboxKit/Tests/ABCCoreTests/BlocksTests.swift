@testable import ABCCore
import XCTest

/// API #171 (a group blocks a writer from its letters) and #172 (a group recommends a site-wide block).
@MainActor
final class BlocksTests: XCTestCase {
  private var fake: FakeAPI!
  private var writer: TestApp!
  private var member: TestApp!
  private var group: GroupRepository { member.container.group }

  override func setUp() async throws {
    fake = FakeAPI()
    fake.mode = "server"
    fake.accounts = [
      FakeAPI.Account(id: 9, username: "member1", password: "password1", role: "chapter", chapterId: 1, name: "Sam"),
      FakeAPI.Account(id: 4, username: "user1", password: "password1", name: "Alex"),
    ]
    let fake = fake!
    writer = TestApp { fake.handle($0) }
    member = TestApp { fake.handle($0) }
    try await writer.container.sessions.login(username: "user1", password: "password1")
    try await member.container.sessions.login(username: "member1", password: "password1")
  }

  func testABlockHoldsTheWritersLettersTellsThemWhyAndListsThemForTheGroup() async throws {
    let id = try await writer.container.letters.send(NewLetter(prisonerId: 3, body: "Hello", relayNote: nil, relayChapter: 1)).id
    let held = try await group.block(writerId: 4, reason: "  Repeated threats in letters.  ")
    XCTAssertEqual(held, 1)
    XCTAssertEqual(member.requests(to: "/chapter/block", method: "POST").last?.json as NSDictionary?, ["user": 4, "reason": "Repeated threats in letters."])

    let letter = try await writer.container.letters.letter(messageId: id)
    XCTAssertEqual(letter.heldReason, .writerBlocked); XCTAssertTrue(letter.isHeld)

    // The feed names nobody; the group and its reason are kept for the app to say inside, beside the letter.
    let feed = await writer.container.activity.sync()
    XCTAssertEqual(feed.last?.kind, .writerBlocked)
    XCTAssertEqual(feed.last?.sentence, "A group will not mail your letters any more. Open the app to see which, and why.")
    XCTAssertEqual(writer.container.activity.blockNotice(groupId: 1), GroupBlockNotice(groupName: "Test Chapter", reason: "Repeated threats in letters."))

    let blocks = try await group.blocks()
    XCTAssertEqual(blocks.map(\.writerName), ["Alex"]); XCTAssertEqual(blocks.first?.reason, "Repeated threats in letters.")

    let released = try await group.unblock(writerId: 4)
    XCTAssertEqual(released, 1)
    _ = await writer.container.activity.sync()
    XCTAssertNil(writer.container.activity.blockNotice(groupId: 1), "a lifted block is forgotten")
    let after = try await writer.container.letters.letter(messageId: id)
    XCTAssertFalse(after.isHeld)
  }

  func testABlockedWriterSendingToThatGroupGetsItsOwnRefusal() async throws {
    _ = try await group.block(writerId: 4, reason: "Spam.")
    await assertThrowsAppError(try await writer.container.letters.send(NewLetter(prisonerId: 3, body: "Hello again", relayNote: nil, relayChapter: 1))) {
      XCTAssertEqual($0, .groupBlock("Test Chapter is not mailing letters from this account."))
      XCTAssertEqual(OutboxRepository.refusal($0), "The group that mails to this facility is not mailing letters from your account.", "the outbox keeps it, in the app's words")
    }
  }

  func testAReasonIsRequiredAndARecommendationIsOnePerWriter() async throws {
    await assertThrowsAppError(try await group.block(writerId: 4, reason: "   ")) { XCTAssertEqual($0, .validation(["Give a reason."])) }
    await assertThrowsAppError(try await group.recommendBan(writerId: 4, reason: String(repeating: "x", count: 1001))) {
      XCTAssertEqual($0, .validation(["The reason can be at most 1000 characters."]))
    }
    XCTAssertEqual(member.requests(to: "/chapter/block", method: "POST").count + member.requests(to: "/moderation/ban-recommendation", method: "POST").count, 0)

    try await group.recommendBan(writerId: 4, reason: "Threats to a volunteer.")
    await assertThrowsAppError(try await group.recommendBan(writerId: 4, reason: "Again.")) { XCTAssertEqual($0.conflictCondition, "pending") }
    let recs = try await group.banRecommendations()
    XCTAssertEqual(recs.map(\.status), [.pending]); XCTAssertEqual(recs.first?.writerName, "Alex"); XCTAssertEqual(recs.first?.reason, "Threats to a volunteer.")
  }

  func testTheFeedWordsTheGroupsAndTheSuperadminsEvents() {
    XCTAssertEqual(Activity.kind(event: "group.block", status: nil, action: "blocked"), .groupBlock(lifted: false))
    XCTAssertEqual(Activity.kind(event: "group.block", status: nil, action: "lifted"), .groupBlock(lifted: true))
    XCTAssertEqual(Activity.kind(event: "writer.block", status: nil, action: "lifted"), .writerUnblocked)
    XCTAssertEqual(Activity.kind(event: "ban.decided", status: nil, decision: "banned"), .banDecided(banned: true))
    XCTAssertEqual(Activity.kind(event: "ban.decided", status: nil, decision: "dismissed"), .banDecided(banned: false))
    XCTAssertEqual(Activity.kind(event: "ban.recommended", status: nil), .banRecommended)
    XCTAssertEqual(HeldReason.from(key: "writer_blocked"), .writerBlocked)
  }

  /// Another server can reuse the same account and group ids: one server's block notice is never shown on another.
  func testABlockNoticeBelongsToTheServerThatSentIt() async throws {
    _ = try await group.block(writerId: 4, reason: "Spam.")
    _ = await writer.container.activity.sync()
    XCTAssertNotNil(writer.container.activity.blockNotice(groupId: 1))
    _ = try await writer.container.devServer.set("http://192.168.1.20:3000")
    try await writer.container.sessions.login(username: "user1", password: "password1")
    XCTAssertNil(writer.container.activity.blockNotice(groupId: 1), "the development server's group 1 is someone else")
  }

  /// Lifting one group's block leaves another group's hold on the same writer alone (API #171).
  func testUnblockingReleasesOnlyThisGroupsHolds() async throws {
    let mine = try await writer.container.letters.send(NewLetter(prisonerId: 3, body: "To group 1", relayNote: nil, relayChapter: 1)).id
    let theirs = try await writer.container.letters.send(NewLetter(prisonerId: 3, body: "To group 2", relayNote: nil, relayChapter: 2)).id
    _ = try await group.block(writerId: 4, reason: "Spam.")
    fake.blocks[2] = [4: "Their reason."]
    if let i = fake.messages.firstIndex(where: { $0["id"] as? Int == theirs }) { fake.messages[i]["heldReason"] = "writer_blocked" }
    let released = try await group.unblock(writerId: 4)
    XCTAssertEqual(released, 1)
    let mineAfter = try await writer.container.letters.letter(messageId: mine), theirsAfter = try await writer.container.letters.letter(messageId: theirs)
    XCTAssertFalse(mineAfter.isHeld); XCTAssertEqual(theirsAfter.heldReason, .writerBlocked)
  }
}
