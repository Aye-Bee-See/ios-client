@testable import ABCCore
import ABCCrypto
import XCTest

/// Group roles (API PR #115): one group-owner admin per group, who alone hands the key out, takes it back, or
/// passes the role on; every group admin told of every change. Against the fake API, with real sealed boxes.
@MainActor
final class GroupRolesTests: XCTestCase {
  private var fake: FakeAPI!
  private var sam: TestApp!
  private var noor: TestApp!

  override func setUp() async throws {
    fake = FakeAPI()
    fake.mode = "e2e"
    fake.accounts = [
      FakeAPI.Account(id: 9, username: "member1", password: "password1", role: "chapter", chapterId: 1, name: "Sam"),
      FakeAPI.Account(id: 10, username: "member2", password: "password2", role: "chapter", chapterId: 1, name: "Noor"),
    ]
    let fake = fake!
    sam = TestApp { fake.handle($0) }
    noor = TestApp { fake.handle($0) }
    try await sam.container.sessions.login(username: "member1", password: "password1")
    sam.container.sessions.recoveryCodeSaved()
  }

  /// The set-up at sign-in, as the app runs it: the first group admin to make the key becomes the owner.
  private func samSetsUp() async { _ = await sam.container.group.setUpKeys() }

  func testTheFirstGroupAdminToSetUpTheKeyBecomesTheOwnerAndTheNextOneIsWaitingWithNothingToPress() async throws {
    await samSetsUp()
    XCTAssertEqual(fake.owners[1], 9)
    guard case .ready(let key) = sam.container.group.keyState else { return XCTFail("Sam's key") }
    XCTAssertTrue(key.isOwner)
    var roster = try await sam.container.group.roster()
    XCTAssertTrue(roster.iAmOwner); XCTAssertEqual(roster.ownerId, 9); XCTAssertEqual(roster.owner?.name, "Sam")
    XCTAssertEqual(roster.waiting, [], "Noor has not signed in: nothing to seal to yet")

    try await noor.container.sessions.login(username: "member2", password: "password2")
    roster = try await sam.container.group.roster()
    XCTAssertEqual(roster.waiting.map(\.name), ["Noor"]); XCTAssertTrue(try XCTUnwrap(roster.members.first { $0.id == 10 }).isWaiting)
    let hers = try await noor.container.group.roster()
    XCTAssertFalse(hers.iAmOwner); XCTAssertEqual(hers.owner?.name, "Sam"); XCTAssertEqual(hers.members.first { $0.isMe }?.isWaiting, true)
    let noorsState = await noor.container.group.refreshKeyState()
    guard case .notHeld = noorsState else { return XCTFail("Noor waits for the key: \(noorsState)") }
    // Nothing to press: she cannot hand the key, not even to herself.
    await assertThrowsAppError(try await noor.container.group.handKey(to: 10)) { XCTAssertTrue($0.isForbidden) }
    // And the set-up at sign-in shows her nobody to hand to, because that is the owner's to do.
    let hersToDo = await noor.container.group.setUpKeys()
    XCTAssertEqual(hersToDo.membersWaiting, [])
    let samsToDo = await sam.container.group.setUpKeys()
    XCTAssertEqual(samsToDo.membersWaiting.map(\.name), ["Noor"])
  }

  func testMakeOwnerIsRefusedOnThePhoneForAGroupAdminWhoDoesNotHoldTheKeyAndPassesTheRoleOnForOneWhoDoes() async throws {
    await samSetsUp()
    try await noor.container.sessions.login(username: "member2", password: "password2")
    let group = sam.container.group
    let waitingRoster = try await group.roster()
    let waiting = try XCTUnwrap(waitingRoster.members.first { $0.id == 10 })
    await assertThrowsAppError(try await group.makeOwner(waiting)) { XCTAssertEqual($0, GroupRepository.handKeyFirst) }
    XCTAssertEqual(sam.requests(to: "/auth/chapter-owner").count, 0, "not sent: an owner without the key could hand it to nobody")

    try await group.handKey(to: 10)
    let holderRoster = try await group.roster()
    let holder = try XCTUnwrap(holderRoster.members.first { $0.id == 10 })
    XCTAssertTrue(holder.holdsGroupKey)
    try await group.makeOwner(holder)
    XCTAssertEqual(try XCTUnwrap(sam.requests(to: "/auth/chapter-owner", method: "PUT").first).json as NSDictionary, ["chapter": 1, "user": 10])
    let after = try await group.roster()
    XCTAssertFalse(after.iAmOwner); XCTAssertEqual(after.ownerId, 10); XCTAssertEqual(after.owner?.name, "Noor")
    guard case .ready(let samsKey) = group.keyState else { return XCTFail() }
    XCTAssertFalse(samsKey.isOwner, "the loaded key was reloaded"); XCTAssertTrue(samsKey.keyPair.privateKey.count == 32, "and Sam still holds the key")
    // The old owner has lost the right to hand or withdraw.
    await assertThrowsAppError(try await group.handKey(to: 10)) { XCTAssertTrue($0.isForbidden) }
    await assertThrowsAppError(try await group.stopHandingKey(to: 10)) { XCTAssertTrue($0.isForbidden) }
    // The new owner has it, and her loaded key says so on her next look.
    let hers = await noor.container.group.refreshKeyState()
    guard case .ready(let noorsKey) = hers else { return XCTFail("Noor holds the key: \(hers)") }
    XCTAssertTrue(noorsKey.isOwner)
    let r79 = try await noor.container.group.roster()
    XCTAssertTrue(r79.iAmOwner)
  }

  func testEveryGroupAdminIsToldOfEveryChangeInWordsThatSayYouWhenItIsThem() async throws {
    await samSetsUp()
    try await noor.container.sessions.login(username: "member2", password: "password2")
    // Sam set the key up and became owner: Noor is told both; Sam, the actor, is told neither.
    var hers = await noor.container.activity.sync()
    XCTAssertEqual(Set(hers.map(\.sentence)), ["Your group now has an encryption key.", "Your group has a new group-owner admin."])
    XCTAssertTrue(hers.allSatisfy(\.kind.concernsGroupKey))
    let news90 = await sam.container.activity.sync()
    XCTAssertEqual(news90.map(\.sentence), [])

    let before = await noor.container.group.refreshKeyState()
    guard case .notHeld = before else { return XCTFail("\(before)") }
    try await sam.container.group.handKey(to: 10)
    hers = await noor.container.activity.sync(announce: true) // as the background fetch calls it: no screen involved
    XCTAssertEqual(hers.map(\.sentence), ["You have been handed the group key. Letters will open from your next refresh."])
    XCTAssertEqual(hers.first?.kind, .groupKeyHanded(toMe: true))
    XCTAssertTrue(noor.container.keyring.state.isReady, "the feed itself reloaded the key: nothing else was asked")

    let holderRoster = try await sam.container.group.roster()
    let holder = try XCTUnwrap(holderRoster.members.first { $0.id == 10 })
    try await sam.container.group.makeOwner(holder)
    let news101 = await noor.container.activity.sync()
    XCTAssertEqual(news101.map(\.sentence), ["You are now your group's group-owner admin."])
    let news103 = await sam.container.activity.sync()
    XCTAssertEqual(news103.map(\.sentence), ["Your group has a new group-owner admin."])

    // Now Noor, the owner, withdraws Sam's copy: Sam is told in the second person.
    try await noor.container.group.stopHandingKey(to: 9)
    let his = await sam.container.activity.sync()
    XCTAssertEqual(his.map(\.sentence), ["Your copy of the group key has been withdrawn."])
    XCTAssertEqual(his.first?.kind, .groupKeyRemoved(fromMe: true))

    // The other wordings, and an action this version has never heard of.
    XCTAssertEqual(Activity.kind(event: "group.key", status: nil, action: "handed", member: 7, me: 9), .groupKeyHanded(toMe: false))
    XCTAssertEqual(Activity(id: 1, kind: .groupKeyHanded(toMe: false), chatId: nil, messageId: nil).sentence, "The group key was handed to another group admin.")
    XCTAssertEqual(Activity(id: 1, kind: .groupKeyRemoved(fromMe: false), chatId: nil, messageId: nil).sentence, "A group admin's copy of the group key was withdrawn.")
    XCTAssertEqual(Activity.kind(event: "group.key", status: nil, action: "rotated"), .groupKeyRotated)
    XCTAssertEqual(Activity.kind(event: "group.key", status: nil, action: "shredded"), .other)
    XCTAssertEqual(Activity.kind(event: "group.waiting", status: nil, member: 3), .groupWaiting)
    XCTAssertFalse(Activity.Kind.groupWaiting.concernsGroupKey, "nothing about this account's key changed")
    XCTAssertEqual(Activity.kind(event: "group.owner", status: nil, owner: 7, me: nil), .groupOwner(me: false), "signed out, nothing is you")
  }

  func testAGroupOwnerAdminWithOtherGroupAdminsIsToldNotYetBeforeTypingAnythingAndTheServersRefusalIsWordedByItsCode() async throws {
    await samSetsUp()
    try await noor.container.sessions.login(username: "member2", password: "password2")
    let preview = await sam.container.accountDeletion.preview()
    XCTAssertTrue(preview.isOwnerWithOtherAdmins); XCTAssertTrue(preview.isLastKeyHolder, "both stand in the way; the screen shows ownership first")
    XCTAssertEqual(preview.membersWhoCouldHoldTheKey, ["Noor"])
    // Asked all the same (a stale screen, another device): the server's 409 carries a condition, and the app words it.
    await assertThrowsAppError(try await sam.container.accountDeletion.deleteMyAccount(password: "password1")) { XCTAssertEqual($0, AccountDeletion.ownerRefusal) }
    XCTAssertTrue(sam.container.sessions.state.isSignedIn)

    // Hand the key on and pass the role: now Sam may go, and Noor, the sole holder, may not.
    try await sam.container.group.handKey(to: 10)
    let handed = try await sam.container.group.roster()
    try await sam.container.group.makeOwner(try XCTUnwrap(handed.members.first { $0.id == 10 }))
    let p137 = await sam.container.accountDeletion.preview()
    XCTAssertFalse(p137.isOwnerWithOtherAdmins)
    try await noor.container.group.stopHandingKey(to: 9)
    let noorsPreview = await noor.container.accountDeletion.preview()
    XCTAssertTrue(noorsPreview.isOwnerWithOtherAdmins); XCTAssertTrue(noorsPreview.isLastKeyHolder)
    // A last-holder refusal by its code too.
    fake.owners[1] = 9 // a superadmin moved ownership back meanwhile; Noor is still the only holder
    await assertThrowsAppError(try await noor.container.accountDeletion.deleteMyAccount(password: "password2")) { XCTAssertEqual($0, AccountDeletion.lastHolderRefusal) }
    // A refusal without a code keeps the server's own sentence.
    XCTAssertEqual(AppError.conflict("Something else.", name: "AccountDeleteError").conflictCondition, nil)
  }

  func testAnAPIFromBeforeTheRolesNamesNoOwnerAndAnyHolderMayHandTheKeyAsBefore() async throws {
    fake.predatesGroupRoles = true
    await samSetsUp()
    try await noor.container.sessions.login(username: "member2", password: "password2")
    let roster = try await sam.container.group.roster()
    XCTAssertNil(roster.ownerId); XCTAssertNil(roster.owner); XCTAssertTrue(roster.iAmOwner, "a holder: the old rule")
    let r155 = try await noor.container.group.roster()
    XCTAssertFalse(r155.iAmOwner, "not a holder")
    XCTAssertEqual(roster.waiting, [], "the older API says nothing about waiting")
    try await sam.container.group.handKey(to: 10)
    let r159 = try await noor.container.group.roster()
    XCTAssertTrue(r159.iAmOwner, "now a holder")
    guard case .ready(let key) = sam.container.group.keyState else { return XCTFail() }
    XCTAssertFalse(key.isOwner, "the bundle says nothing, so nothing is claimed")
    let p163 = await sam.container.accountDeletion.preview()
    XCTAssertFalse(p163.isOwnerWithOtherAdmins)
  }
}
