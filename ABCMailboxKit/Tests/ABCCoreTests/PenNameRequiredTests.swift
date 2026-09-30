@testable import ABCCore
import ABCCrypto
import XCTest

/// API #168: a pen name is required when an account is made, and a writer without one is asked at sign-in.
@MainActor
final class PenNameRequiredTests: XCTestCase {
  private var fake: FakeAPI!
  private var app: TestApp!
  private var sessions: SessionRepository { app.container.sessions }
  private let password = "Lantern river quiet map 4"
  private let invitation = "7K2M9QX4T8VB3N6Y1RZC5WDH"

  override func setUp() async throws {
    fake = FakeAPI()
    fake.mode = "e2e"
    fake.requirePenName = true
    fake.invitations[invitation] = ("member", 1, "pending", "immediate")
    let fake = fake!
    app = TestApp { fake.handle($0) }
  }

  func testAcceptingWithoutAPenNameIsRefusedUnderTheFieldAndTheInvitationStaysUsable() async throws {
    let info = try await sessions.invitationInfo(token: invitation)
    await assertThrowsAppError(try await sessions.acceptInvitation(token: invitation, info: info, username: "riverside", password: password, email: "r@example.com", name: nil, penName: "  ", group: nil)) {
      XCTAssertEqual(FormErrors($0, fields: ["penName": "pen name"]).byField, ["penName": "Pen name is needed."])
    }
    XCTAssertNil(app.requests(to: "/invitation/accept").last?.json["penName"], "a blank name is not sent")
    try await sessions.acceptInvitation(token: invitation, info: info, username: "riverside", password: password, email: "r@example.com", name: nil, penName: "Ada Lovelace", group: nil)
    XCTAssertEqual(app.requests(to: "/invitation/accept").last?.json["penName"] as? String, "Ada Lovelace")
  }

  func testAClaimOffersTheGroupsNameAndKeepsItWithoutSendingIt() async throws {
    let writer = Sodium.keypair()
    let made = try GroupKeys.claimToken(writerPrivateKey: writer.privateKey)
    var managed = FakeAPI.Account(id: 47, username: "managed-47", password: "unknowable", managedBy: 1,
      keys: ["publicKey": Sodium.toBase64(writer.publicKey)], orgWrappedPrivateKey: "sealed-to-group",
      claim: ["tokenHash": made.tokenHash, "claimWrappedPrivateKey": made.wrapped.wrapped, "claimSalt": made.wrapped.salt, "claimKdfParams": ["kdf": "argon2id", "alg": 2, "opslimit": 2, "memlimit": 67_108_864]], name: "Alex")
    managed.penName = "Alex Rivers"
    fake.accounts = [managed]

    let info = try await sessions.claimInfo(token: made.token)
    XCTAssertEqual(info.writerPenName, "Alex Rivers")
    try await sessions.claim(token: made.token, username: "alex", password: password, email: nil, penName: nil)
    XCTAssertNil(app.requests(to: "/auth/claim", method: "POST").last?.json["penName"])
    XCTAssertEqual(fake.accounts[0].penName, "Alex Rivers", "the group's name stays the writer's")
  }

  func testOnlyAWriterTheServerSaysHasNoPenNameIsAsked() async throws {
    fake.accounts = [FakeAPI.Account(id: 4, username: "user1", password: "password1"), FakeAPI.Account(id: 9, username: "member1", password: "password1", role: "chapter", chapterId: 1)]
    try await sessions.login(username: "user1", password: "password1", olderAccount: true)
    let isMissing = await app.container.penNames.isMissing()
    XCTAssertTrue(isMissing)

    fake.accounts[0].penName = "Ada Lovelace"
    let named = await app.container.penNames.isMissing()
    XCTAssertFalse(named)

    fake.accounts[0].penName = nil
    fake.noSignal = true
    let offline = await app.container.penNames.isMissing()
    XCTAssertFalse(offline, "an unreachable server asks nothing")
    fake.noSignal = false

    try await sessions.logout(everywhere: false)
    try await sessions.login(username: "member1", password: "password1", olderAccount: true)
    let staff = await app.container.penNames.isMissing()
    XCTAssertFalse(staff, "staff accounts an admin made sign no letters and need none")
  }
}
