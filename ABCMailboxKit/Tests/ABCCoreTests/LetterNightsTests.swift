@testable import ABCCore
import XCTest

/// The API's changes of 19 to 21 September as its brief to the mobile clients lists them: the print queue in
/// one request and several letters marked at once (API PR #111), a group's numbers (API PR #112), a group
/// that is not active yet, and a group key that rotated while it was being handed over.
@MainActor
final class LetterNightsTests: XCTestCase {
  private var fake: FakeAPI!
  private var writer: TestApp!
  private var member: TestApp!
  private var group: GroupRepository { member.container.group }

  override func setUp() async throws {
    fake = FakeAPI()
    fake.mode = "server"
    fake.accounts = [
      FakeAPI.Account(id: 9, username: "member1", password: "password1", role: "chapter", chapterId: 1, name: "Sam"),
      FakeAPI.Account(id: 10, username: "member2", password: "password2", role: "chapter", chapterId: 1, name: "Noor"),
      FakeAPI.Account(id: 4, username: "user1", password: "password1"),
    ]
    let fake = fake!
    writer = TestApp { fake.handle($0) }
    member = TestApp { fake.handle($0) }
    try await writer.container.sessions.login(username: "user1", password: "password1")
  }

  private func signInMember() async throws { try await member.container.sessions.login(username: "member1", password: "password1") }

  private func queued(_ count: Int) async throws -> [Int] {
    var ids: [Int] = []
    for i in 1...count { ids.append(try await writer.container.letters.send(NewLetter(prisonerId: 3, body: "Letter \(i)", relayNote: nil, relayChapter: 1)).id) }
    return ids
  }

  func testTheQueueIsOneRequestAndAnOlderAPIStillGetsItsPrisonersLookedUp() async throws {
    try await signInMember()
    _ = try await queued(3)
    let page = try await group.queue(groupId: 1, status: .queued, page: 1, pageSize: 20)
    XCTAssertEqual(page.items.count, 3); XCTAssertEqual(page.items.first?.prisoner?.facility?.name, "Test Prison")
    XCTAssertEqual(member.requests(to: "/messaging/messages").last?.query["full"], "true")
    XCTAssertEqual(member.requests(to: "/prisoner/prisoner").count, 0, "rows bring the prisoner and the facility with them")
    let one = try await group.queueItem(messageId: page.items[0].id)
    XCTAssertNotNil(one.prisoner)

    fake.predatesLetterNights = true
    let older = try await group.queue(groupId: 1, status: .queued, page: 1, pageSize: 20)
    XCTAssertEqual(older.items.first?.prisoner?.name, "Jane Smith")
    XCTAssertEqual(member.requests(to: "/prisoner/prisoner").count, 1, "one lookup for the one prisoner, remembered for the other rows")
  }

  func testSeveralLettersMoveTogetherAndTheWriterIsToldOnceWithHowMany() async throws {
    try await signInMember()
    let ids = try await queued(3)
    let moved = try await group.setStatusOfMany(messageIds: ids + [ids[0]], status: .printed)
    XCTAssertEqual(moved, 3)
    XCTAssertEqual(try XCTUnwrap(member.requests(to: "/messaging/status/batch", method: "PUT").last).json as NSDictionary, ["ids": ids, "status": "printed"], "numbers, each once, and nothing else")

    let news = await writer.container.activity.sync()
    XCTAssertEqual(news.count, 1); XCTAssertEqual(news.first?.kind, .printed); XCTAssertEqual(news.first?.count, 3); XCTAssertNil(news.first?.messageId)
    XCTAssertEqual(news.first?.sentence, "3 of your letters have been printed.")
    XCTAssertEqual(Activity(id: 1, kind: .mailed, chatId: nil, messageId: nil, count: 2).sentence, "2 of your letters are in the mail.")
    XCTAssertEqual(Activity(id: 1, kind: .reply, chatId: nil, messageId: nil, count: 2).sentence, "A reply to one of your letters has arrived.", "a count means nothing for other news")
  }

  func testOneLetterThatCannotMoveStopsAllOfThemAndTheRefusalNamesIt() async throws {
    try await signInMember()
    let ids = try await queued(3)
    _ = try await group.setStatus(messageId: ids[1], status: .printed)
    await assertThrowsAppError(try await group.setStatusOfMany(messageIds: ids, status: .printed)) {
      XCTAssertEqual($0.userMessage, "Letter \(ids[1]): a printed letter cannot move to printed.")
    }
    let queue = try await group.queue(groupId: 1, status: .queued, page: 1, pageSize: 20)
    XCTAssertEqual(queue.items.map(\.id).sorted(), [ids[0], ids[2]], "nothing moved")
  }

  func testTheBatchHasALimitAndAnOlderAPISaysSoInsteadOfNotFound() async throws {
    try await signInMember()
    await assertThrowsAppError(try await group.setStatusOfMany(messageIds: Array(1...201), status: .printed)) { XCTAssertEqual($0.userMessage, "At most 200 letters can be marked at once.") }
    XCTAssertEqual(member.requests(to: "/messaging/status/batch", method: "PUT").count, 0, "not split quietly: that would stop being all or none")
    let none = try await group.setStatusOfMany(messageIds: [], status: .printed)
    XCTAssertEqual(none, 0)

    fake.predatesLetterNights = true
    let ids = try await queued(2)
    await assertThrowsAppError(try await group.setStatusOfMany(messageIds: ids, status: .printed)) { XCTAssertEqual($0.userMessage, "This server cannot mark several letters at once yet. Mark them one at a time.") }
  }

  func testAMoveSomeoneElseMadeFirstIsNotAFailure() async throws {
    try await signInMember()
    let ids = try await queued(1)
    fake.intercept = { r in r.path == "/messaging/status" ? .error(409, info: "Error updating letter status.", extra: ["name": "LetterStatusError", "error": "Letter \(ids[0]) was changed by someone else meanwhile; nothing was moved."]) : nil }
    await assertThrowsAppError(try await group.setStatus(messageId: ids[0], status: .printed)) { XCTAssertTrue($0.isChangedMeanwhile) }
    XCTAssertFalse(AppError.conflict("A printed letter cannot move to queued.", name: "LetterStatusError").isChangedMeanwhile)
  }

  func testAGroupThatIsNotActiveIsNotOfferedAKeySetUpThatCanOnlyBeRefused() async throws {
    fake.inactiveGroups = [1]
    try await signInMember()
    let setUp = await group.setUpKeys()
    XCTAssertFalse(setUp.madeGroupKey)
    guard case .groupNotActive(let id) = group.keyState else { return XCTFail("expected groupNotActive, got \(group.keyState)") }
    XCTAssertEqual(id, 1)
    XCTAssertEqual(member.requests(to: "/auth/chapter-keys", method: "PUT").count, 0, "nothing was tried")
    await assertThrowsAppError(try await group.handKey(to: 10)) { XCTAssertEqual($0.userMessage, GroupKeyState.groupNotActiveText) }

    // Activated: the next look finds an ordinary group without a key, and sign-in makes one.
    fake.inactiveGroups = []
    let later = await group.setUpKeys()
    XCTAssertTrue(later.madeGroupKey)
  }

  func testHandingTheKeyOverNamesItsVersionAndARotationMeanwhileIsNotHandedOn() async throws {
    try await signInMember()
    _ = await group.setUpKeys()
    let other = TestApp { [fake] in fake!.handle($0) }
    try await other.container.sessions.login(username: "member2", password: "password2") // their own keypair is made at sign-in
    try await group.handKey(to: 10)
    XCTAssertEqual(try XCTUnwrap(member.requests(to: "/auth/member-key", method: "PUT").last).json["keyVersion"] as? Int, fake.groupKeys[1]?.version)

    fake.memberKeys[1]?[10] = nil
    let current = try XCTUnwrap(fake.groupKeys[1])
    fake.groupKeys[1] = (current.publicKey, current.version + 1) // rotated by someone else, a moment ago
    await assertThrowsAppError(try await group.handKey(to: 10)) {
      XCTAssertTrue($0.isKeyRotated); XCTAssertEqual($0.userMessage, "Your group changed its key a moment ago. The new one has been fetched; try again.")
    }
    XCTAssertNil(fake.memberKeys[1]?[10], "the stale key was not handed on")
  }

  func testAGroupsNumbersAreTheServersAndOnlyOneOfThemIsTyped() async throws {
    try await signInMember()
    let first = try await group.numbers()
    let before = try XCTUnwrap(first)
    XCTAssertEqual(before.total, 0); XCTAssertNil(before.published, "nothing, not 0"); XCTAssertNil(before.averageDaysToMail)

    try await group.setLettersSentBefore(25)
    XCTAssertEqual(try XCTUnwrap(member.requests(to: "/chapter/chapter", method: "PUT").last).json as NSDictionary, ["id": 1, "lettersSentBefore": 25], "only the id and the one field")
    let second = try await group.numbers()
    let after = try XCTUnwrap(second)
    XCTAssertEqual(after.before, 25); XCTAssertEqual(after.published, "25"); XCTAssertEqual(after.averageDaysToMail, 6)
    await assertThrowsAppError(try await group.setLettersSentBefore(-1)) { XCTAssertEqual($0.userMessage, "The number cannot be negative.") }

    fake.predatesGroupNumbers = true
    let older = try await group.numbers()
    XCTAssertNil(older, "an API that does not count yet is not a group that mailed nothing")
  }

  func testAGroupsPublishedNumbersAreNothingWhenNullZeroOrBlankAndReadAsTextOrNumber() throws {
    func group(_ json: String) throws -> SupportGroup { try JSONDecoder().decode(ChapterDTO.self, from: Data(json.utf8)).toDomain() }
    XCTAssertNil(try group(#"{"id":1,"name":"G","lettersSent":null,"averageTimeDays":null}"#).lettersSent)
    XCTAssertNil(try group(#"{"id":1,"name":"G"}"#).lettersSent)
    XCTAssertNil(try group(#"{"id":1,"name":"G","lettersSent":"0","averageTimeDays":0}"#).lettersSent)
    XCTAssertNil(try group(#"{"id":1,"name":"G","lettersSent":" ","averageTimeDays":0}"#).averageDaysToMail)
    XCTAssertEqual(try group(#"{"id":1,"name":"G","lettersSent":"140","averageTimeDays":6}"#).lettersSent, "140")
    XCTAssertEqual(try group(#"{"id":1,"name":"G","lettersSent":140}"#).lettersSent, "140")
  }

  func testAMissingLetterSaysWhichOne() async throws {
    try await signInMember()
    fake.intercept = { r in r.path == "/messaging/message" ? .error(404, info: "Error getting message.", extra: ["error": "Message 99999 not found"]) : nil }
    await assertThrowsAppError(try await self.group.queueItem(messageId: 99999)) { XCTAssertEqual($0.userMessage, "Message 99999 not found") }
  }
}
