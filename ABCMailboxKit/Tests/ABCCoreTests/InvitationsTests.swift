@testable import ABCCore
import ABCCrypto
import XCTest

/// Invitations, the third credential beside invite codes and claim tokens: how a group admin comes into being.
/// Against the fake API, on an end-to-end server under REQUIRE_SPLIT_AUTH, with real keys.
@MainActor
final class InvitationsTests: XCTestCase {
  private var fake: FakeAPI!
  private var app: TestApp!
  private let password = "Lantern river quiet map 4"
  private let memberToken = "7K2M9QX4T8VB3N6Y1RZC5WDH"
  private let groupToken = "8K2M9QX4T8VB3N6Y1RZC5WDH"

  override func setUp() async throws {
    fake = FakeAPI()
    fake.mode = "e2e"
    fake.requireSplitAuth = true
    fake.invitations[memberToken] = ("member", 1, "pending", "immediate")
    fake.invitations[groupToken] = ("group", 1, "pending", "admin_review")
    let fake = fake!
    app = TestApp { fake.handle($0) }
  }

  private var sessions: SessionRepository { app.container.sessions }

  func testOneBoxTellsAnInviteCodeFromAnInvitationByLength() {
    XCTAssertEqual(EntryCode.classify("7q4m-2xkd-9hbt"), .inviteCode("7Q4M2XKD9HBT"))
    XCTAssertEqual(EntryCode.classify("7k2m 9qx4 t8vb 3n6y 1rzc 5wdh"), .invitation(memberToken))
    XCTAssertEqual(EntryCode.classify("7K2M-9QX4-T8VB-3N6Y-1RZC-5WDO"), .invitation("7K2M9QX4T8VB3N6Y1RZC5WD0"), "O reads as 0, as the server reads it")
    XCTAssertNil(EntryCode.classify("7K2M-9QX4-T8VB-3N6Y"))
    XCTAssertEqual(EntryCode.problem("7K2M-9QX4-T8VB-3N6Y"), "That is 16 characters. An invite code has 12; an invitation has 24.")
    XCTAssertEqual(EntryCode.problem("7K2M-9QX4-T8VB-3N6Y-1RZC-5WDU"), "Codes never contain the character U. Check for a look-alike.")
    XCTAssertNil(EntryCode.problem(memberToken.lowercased()))
    XCTAssertEqual(InvitationToken.pretty(memberToken), "7K2M-9QX4-T8VB-3N6Y-1RZC-5WDH")
    XCTAssertEqual(InvitationToken.problem("7K2M"), "That is 4 characters; an invitation has 24.")
  }

  func testAMemberInvitationMakesAGroupAdminWithKeysMadeHereAndThePasswordNeverSent() async throws {
    let info = try await sessions.invitationInfo(token: memberToken)
    XCTAssertEqual(info.kind, .member); XCTAssertEqual(info.groupName, "Test Chapter"); XCTAssertFalse(info.waitsForReview)
    XCTAssertNil(app.requests(to: "/invitation/invitation").first?.headers["Authorization"])

    let accepted = try await sessions.acceptInvitation(token: memberToken, info: info, username: "riverside", password: password, email: "r@example.com", name: "Ada", penName: " Ada   Lovelace ", group: NewGroupProfile())
    XCTAssertEqual(accepted, AcceptedInvitation(groupName: "Test Chapter", waitsForReview: false))

    let sent = try XCTUnwrap(app.requests(to: "/invitation/accept", method: "POST").first)
    XCTAssertNil(sent.json["group"], "a member invitation must not carry a group")
    XCTAssertEqual(sent.json["authScheme"] as? String, "split")
    XCTAssertFalse(sent.bodyText.contains(password), "the password never leaves the phone")
    XCTAssertEqual(sent.json["penName"] as? String, "Ada Lovelace")
    for k in ["publicKey", "wrappedPrivateKey", "kdfSalt", "kdfParams", "recoveryWrappedPrivateKey", "recoverySalt", "recoveryKdfParams"] { XCTAssertNotNil(sent.json[k], k) }

    let user = try XCTUnwrap(sessions.state.user)
    XCTAssertEqual(user.role, Role.chapter); XCTAssertEqual(user.chapterId, 1)
    XCTAssertNotNil(app.container.vault.keyPair(for: user.id), "the private key is on this phone")
    XCTAssertNotNil(sessions.pendingRecoveryCode, "the recovery code is shown next")
  }

  func testAGroupInvitationSendsOnlyTheFieldsItAllowsAndSaysTheGroupWaitsForReview() async throws {
    let info = try await sessions.invitationInfo(token: groupToken)
    XCTAssertEqual(info.kind, .group); XCTAssertTrue(info.waitsForReview); XCTAssertTrue(info.groupFields.contains("location"))

    var profile = NewGroupProfile()
    profile.name = " Riverside ABC "; profile.city = "Riverside"; profile.country = "Canada"; profile.website = ""
    let limited = InvitationInfo(kind: .group, inviteeName: nil, groupName: "Test Chapter", expiresAt: nil, waitsForReview: true, groupFields: ["name", "location", "about"])
    XCTAssertEqual(GroupProfileDTO(profile, allowed: limited.groupFields), {
      var d = GroupProfileDTO(NewGroupProfile(), allowed: []); d.name = "Riverside ABC"; d.location = .init(city: "Riverside"); return d
    }(), "country is not in groupFields and the website is blank: neither is sent")

    let accepted = try await sessions.acceptInvitation(token: groupToken, info: info, username: "riverside", password: password, email: "r@example.com", name: nil, penName: nil, group: profile)
    XCTAssertEqual(accepted, AcceptedInvitation(groupName: "Riverside ABC", waitsForReview: true))
    let group = try XCTUnwrap(app.requests(to: "/invitation/accept", method: "POST").first?.json["group"] as? [String: Any])
    XCTAssertEqual(group as NSDictionary, ["name": "Riverside ABC", "location": ["city": "Riverside"], "country": "Canada"])
  }

  func testARefusedAcceptanceLeavesTheInvitationUsableAndAUsedOneSaysSo() async throws {
    fake.accounts = [FakeAPI.Account(id: 3, username: "taken", password: "x")]
    let info = try await sessions.invitationInfo(token: memberToken)
    await assertThrowsAppError(try await sessions.acceptInvitation(token: memberToken, info: info, username: "taken", password: password, email: "t@example.com", name: nil, penName: nil, group: nil)) {
      XCTAssertEqual($0, .validation(["That username is taken."]))
    }
    XCTAssertNil(sessions.state.user)
    try await sessions.acceptInvitation(token: memberToken, info: info, username: "riverside", password: password, email: "r@example.com", name: nil, penName: nil, group: nil)
    try await sessions.logout(everywhere: false)

    await assertThrowsAppError(try await sessions.invitationInfo(token: memberToken)) {
      XCTAssertEqual($0, .gone("Invitation is accepted.", condition: "accepted"))
    }
    await assertThrowsAppError(try await sessions.invitationInfo(token: "0000000000000000000000AB")) { XCTAssertTrue($0.isNotFound) }
  }

  func testWhileTheModeIsUnknownNothingIsAccepted() async throws {
    let fake = fake!
    app = TestApp { r in r.path == "/health" ? Stubbed(status: -1) : fake.handle(r) }
    let info = try await sessions.invitationInfo(token: memberToken)
    await assertThrowsAppError(try await sessions.acceptInvitation(token: memberToken, info: info, username: "riverside", password: password, email: "r@example.com", name: nil, penName: nil, group: nil)) {
      XCTAssertEqual($0, .network)
    }
    XCTAssertEqual(app.requests(to: "/invitation/accept").count, 0)
  }
}
