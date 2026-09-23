@testable import ABCCore
import ABCCrypto
import XCTest

/// Invite codes (API PR #116): a chapter prints slips, a newcomer joins with one. Against the fake API, with real
/// keys, on an end-to-end server under REQUIRE_SPLIT_AUTH, which is what production will be.
@MainActor
final class InviteCodesTests: XCTestCase {
  private var fake: FakeAPI!
  private var member: TestApp!
  private var newcomer: TestApp!
  private let password = "Lantern river quiet map 4"

  override func setUp() async throws {
    fake = FakeAPI()
    fake.mode = "e2e"
    fake.requireSplitAuth = true
    fake.accounts = [FakeAPI.Account(id: 9, username: "member1", password: "password1", role: "chapter", chapterId: 1, name: "Sam")]
    let fake = fake!
    member = TestApp { fake.handle($0) }
    newcomer = TestApp { fake.handle($0) }
    try await member.container.sessions.login(username: "member1", password: "password1")
  }

  func testACodeIsReadTheWayTheServerReadsItAndCheckedBeforeAnyRequest() throws {
    XCTAssertEqual(InviteCode.normalise(" 7q4m-2xkd-9hbt "), "7Q4M2XKD9HBT")
    XCTAssertEqual(InviteCode.normalise("7O4M-2XKD-9HBl"), "704M2XKD9HB1", "O reads as 0, I and L as 1")
    XCTAssertEqual(InviteCode.pretty("7q4m2xkd9hbt"), "7Q4M-2XKD-9HBT")
    XCTAssertTrue(InviteCode.isWellFormed("7Q4M-2XKD-9HBT")); XCTAssertFalse(InviteCode.isWellFormed("7Q4M-2XKD-9HB"))
    XCTAssertEqual(InviteCode.problem(""), "Enter the code on your slip.")
    XCTAssertEqual(InviteCode.problem("7Q4M-2XKD-9HB"), "That is 11 characters; a code has 12.")
    XCTAssertEqual(InviteCode.problem("7Q4M-2XKD-9HBU"), "Codes never contain the character U. Check for a look-alike.")
    XCTAssertNil(InviteCode.problem("7q4m 2xkd 9hbt"))
    XCTAssertEqual(InviteCode.link(try XCTUnwrap(URL(string: "https://letters.support/join?code=7Q4M-2XKD-9HBT")))?.code, "7Q4M-2XKD-9HBT")
    XCTAssertEqual(InviteCode.link(try XCTUnwrap(URL(string: "abcmailbox://join?code=7Q4M2XKD9HBT")))?.code, "7Q4M2XKD9HBT")
    XCTAssertEqual(InviteCode.link(try XCTUnwrap(URL(string: "abcmailbox://join"))), InviteCode.Link(code: nil))
    XCTAssertNil(InviteCode.link(try XCTUnwrap(URL(string: "abcmailbox://claim?token=x"))))
    XCTAssertNil(InviteCode.link(try XCTUnwrap(URL(string: "https://letters.support/prisoners"))))
    XCTAssertEqual(InviteCode.webLink("7q4m2xkd9hbt"), "https://letters.support/join?code=7Q4M-2XKD-9HBT")
  }

  func testAChapterIssuesABatchSeesItOnceThenOnlyCounts() async throws {
    let group = member.container.group
    let issued = try await group.issueInviteCodes(count: 3, label: "Letter night, 2 October", days: nil)
    XCTAssertEqual(try XCTUnwrap(member.requests(to: "/auth/invite-codes", method: "POST").first).json as NSDictionary, ["count": 3, "label": "Letter night, 2 October"])
    XCTAssertEqual(issued.codes.count, 3); XCTAssertTrue(issued.codes.allSatisfy(InviteCode.isWellFormed)); XCTAssertEqual(issued.outstanding, 3); XCTAssertEqual(issued.limit, 20)
    XCTAssertNotNil(issued.expiresAt)
    let quota = try await group.inviteCodes()
    XCTAssertEqual(quota.outstanding, 3); XCTAssertEqual(quota.batches.count, 1)
    let batch = try XCTUnwrap(quota.batches.first)
    XCTAssertEqual(batch.label, "Letter night, 2 October"); XCTAssertEqual(batch.total, 3); XCTAssertEqual(batch.unused, 3); XCTAssertEqual(batch.used, 0)
    XCTAssertFalse(member.requests(to: "/auth/invite-codes", method: "GET").last!.bodyText.contains(issued.codes[0]), "never the codes again")

    // Over the quota: the server's sentence, with its numbers.
    await assertThrowsAppError(try await group.issueInviteCodes(count: 18, label: nil, days: nil)) { XCTAssertEqual($0, .conflict("This chapter has 3 unused codes and may have 20; 18 more would go over.", name: "InviteQuotaError")) }
    await assertThrowsAppError(try await group.issueInviteCodes(count: 51, label: nil, days: nil)) { XCTAssertEqual($0, .validation(["Between 1 and 50 codes at a time."])) }

    let cancelled = try await group.cancelInviteCodes(batch: batch.id)
    XCTAssertEqual(cancelled, 3)
    XCTAssertEqual(try XCTUnwrap(member.requests(to: "/auth/invite-codes", method: "DELETE").last).json as NSDictionary, ["batch": batch.id])
    let after = try await group.inviteCodes()
    XCTAssertEqual(after.outstanding, 0); XCTAssertEqual(after.batches.first?.cancelled, 3)
    // A code from the cancelled batch is dead, and says so by its code.
    await assertThrowsAppError(try await newcomer.container.sessions.joinInfo(code: InviteCode.normalise(issued.codes[0]))) { XCTAssertEqual($0.goneBecause, "cancelled") }
  }

  func testANewcomerJoinsWithTheKeysMadeOnThePhoneAndThePasswordIsNowhere() async throws {
    let issued = try await member.container.group.issueInviteCodes(count: 2, label: nil, days: nil)
    let typed = " " + issued.codes[0].lowercased() + " "
    let info = try await newcomer.container.sessions.joinInfo(code: InviteCode.normalise(typed))
    XCTAssertEqual(info.groupName, "Test Chapter"); XCTAssertEqual(info.groupId, 1); XCTAssertNotNil(info.expiresAt)
    XCTAssertNil(newcomer.requests(to: "/auth/join", method: "GET").first?.headers["Authorization"], "public")

    try await newcomer.container.sessions.join(code: InviteCode.normalise(typed), username: "sam-new", password: password, email: "  ", name: "Sam")
    let sent = try XCTUnwrap(newcomer.requests(to: "/auth/join", method: "POST").first).json
    XCTAssertEqual(sent["authScheme"] as? String, "split"); XCTAssertEqual((sent["password"] as? String)?.count, 44)
    XCTAssertNil(sent["email"], "a blank email is left out"); XCTAssertEqual(sent["name"] as? String, "Sam")
    for k in ["publicKey", "wrappedPrivateKey", "kdfSalt", "kdfParams", "recoveryWrappedPrivateKey", "recoverySalt", "recoveryKdfParams"] { XCTAssertNotNil(sent[k], k) }
    XCTAssertFalse(newcomer.requests.contains { $0.bodyText.contains(password) })

    let user = try XCTUnwrap(newcomer.container.sessions.state.user)
    XCTAssertEqual(user.username, "sam-new"); XCTAssertEqual(user.sponsoredBy, 1); XCTAssertEqual(user.role, Role.user)
    XCTAssertNotNil(newcomer.container.vault.keyPair(for: user.id), "the key made here opens, after the one-derivation sign-in")
    XCTAssertFalse(newcomer.container.sessions.keysLocked)
    let code = try XCTUnwrap(newcomer.container.sessions.pendingRecoveryCode, "shown once, cannot be skipped")
    let k = fake.accounts.last!.keys
    XCTAssertEqual(try AccountKeys.unlockWithCode(publicKey: k["publicKey"] as! String, wrapped: k["recoveryWrappedPrivateKey"] as! String, code: code, salt: k["recoverySalt"] as! String, params: .standard).privateKey, newcomer.container.vault.keyPair(for: user.id)?.privateKey)
    XCTAssertTrue(newcomer.container.schemes.isKnownSplit("sam-new"))
    XCTAssertEqual(newcomer.requests(to: "/auth/keys", method: "PUT").count, 0, "the keys went with the join; nothing to add at sign-in")

    // The code is spent. The other one still works; a used one says so by its code.
    await assertThrowsAppError(try await newcomer.container.sessions.joinInfo(code: InviteCode.normalise(issued.codes[0]))) { XCTAssertEqual($0.goneBecause, "used") }
    let quota = try await member.container.group.inviteCodes()
    XCTAssertEqual(quota.batches.first?.used, 1); XCTAssertEqual(quota.outstanding, 1)
  }

  func testATakenUsernameDoesNotSpendTheCodeAndTheOtherRefusalsAreWordedByTheirCode() async throws {
    let issued = try await member.container.group.issueInviteCodes(count: 1, label: nil, days: nil)
    let code = InviteCode.normalise(issued.codes[0])
    await assertThrowsAppError(try await newcomer.container.sessions.join(code: code, username: "member1", password: password, email: nil, name: nil)) { XCTAssertEqual($0, .validation(["That username is taken."])) }
    XCTAssertFalse(newcomer.container.sessions.state.isSignedIn)
    _ = try await newcomer.container.sessions.joinInfo(code: code) // still usable
    try await newcomer.container.sessions.join(code: code, username: "someone", password: password, email: nil, name: nil)
    XCTAssertTrue(newcomer.container.sessions.state.isSignedIn)

    await assertThrowsAppError(try await newcomer.container.sessions.joinInfo(code: "7Q4M2XKD9HBT")) { XCTAssertTrue($0.isNotFound, "never issued") }
    fake.inactiveGroups = [1]
    let another = TestApp { [fake] in fake!.handle($0) }
    fake.inviteCodes["AAAABBBBCCCC"] = ("batchx", 1, "unused")
    await assertThrowsAppError(try await another.container.sessions.joinInfo(code: "AAAABBBBCCCC")) { XCTAssertEqual($0.goneBecause, "inactive") }
    fake.inactiveGroups = []
    fake.inviteCodes["AAAABBBBCCCC"] = ("batchx", 1, "expired")
    await assertThrowsAppError(try await another.container.sessions.joinInfo(code: "AAAABBBBCCCC")) { XCTAssertEqual($0.goneBecause, "expired") }
  }

  func testOnAServerModeAPITheJoinIsSplitWithASaltAndNoKeys() async throws {
    fake.mode = "server"
    let issued = try await member.container.group.issueInviteCodes(count: 1, label: nil, days: nil)
    try await newcomer.container.sessions.join(code: InviteCode.normalise(issued.codes[0]), username: "plainer", password: password, email: nil, name: nil)
    let sent = try XCTUnwrap(newcomer.requests(to: "/auth/join", method: "POST").first).json
    XCTAssertEqual(sent["authScheme"] as? String, "split"); XCTAssertNotNil(sent["kdfSalt"]); XCTAssertNotNil(sent["kdfParams"]); XCTAssertNil(sent["wrappedPrivateKey"])
    XCTAssertTrue(newcomer.container.sessions.state.isSignedIn)
    XCTAssertEqual(newcomer.requests(to: "/auth/keys", method: "PUT").count, 1, "keys are made at that first sign-in, under the wrap key, as for any split account without them")
  }
}
