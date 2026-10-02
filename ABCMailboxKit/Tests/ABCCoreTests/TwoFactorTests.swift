@testable import ABCCore
import ABCCrypto
import XCTest

/// Two-factor sign-in (API #173, #175) against the fake API, on an end-to-end server, with real keys.
@MainActor
final class TwoFactorTests: XCTestCase {
  private var fake: FakeAPI!
  private var app: TestApp!
  private var sessions: SessionRepository { app.container.sessions }
  private var twoFactor: TwoFactorRepository { app.container.twoFactor }
  private let password = "pässword1"

  override func setUp() async throws {
    fake = FakeAPI()
    fake.mode = "e2e"
    fake.accounts = [FakeAPI.Account(id: 4, username: "user1", password: password)]
    let fake = fake!
    app = TestApp { fake.handle($0) }
  }

  /// Signed in once (which makes the keys), two-factor sign-in switched on, signed out, and the key gone from the phone.
  private func accountWithTwoFactorOn() async throws -> [String] {
    try await sessions.login(username: "user1", password: password)
    sessions.recoveryCodeSaved()
    let setup = try await twoFactor.setup()
    XCTAssertTrue(setup.otpauthUri.hasPrefix("otpauth://totp/"))
    let codes = try await twoFactor.confirm(code: "123 456")
    XCTAssertEqual(app.requests(to: "/auth/two-factor/confirm").first?.json["code"] as? String, "123456", "spaces are dropped before sending")
    XCTAssertEqual(codes.count, 10)
    try await sessions.logout()
    app.container.vault.clear()
    fake.currentCode = "654321"
    return codes
  }

  func testTheRightPasswordWaitsForACodeAndTheCodeFinishesTheSignInAndOpensTheKey() async throws {
    _ = try await accountWithTwoFactorOn()
    await assertThrowsAppError(try await sessions.login(username: " user1 ", password: password)) { XCTAssertEqual($0, .twoFactorCodeNeeded) }
    XCTAssertNil(sessions.state.user, "no session until the code")
    XCTAssertEqual(sessions.twoFactorChallenge?.username, "user1")

    // A wrong code keeps the sign-in waiting, under the field it is about.
    await assertThrowsAppError(try await sessions.completeTwoFactor(code: "111111")) {
      XCTAssertEqual($0.fieldProblems.first?.field, "code"); XCTAssertEqual($0.fieldProblems.first?.code, "not_eligible")
    }
    XCTAssertNotNil(sessions.twoFactorChallenge)

    let session = try await sessions.completeTwoFactor(code: "654-321")
    XCTAssertEqual(session.user.id, 4)
    XCTAssertNil(sessions.twoFactorChallenge)
    XCTAssertNotNil(app.container.vault.keyPair(for: 4), "the private key opens with the password typed at the first step")
    XCTAssertFalse(sessions.keysLocked)
    XCTAssertNil(app.requests(to: "/auth/login/two-factor").first?.headers["Authorization"])
    XCTAssertFalse(app.requests(to: "/auth/login/two-factor").contains { $0.bodyText.contains(password) }, "the second step never carries the password")
  }

  func testARecoveryCodeFinishesTheSignInOnceAndAUsedChallengeGoesBackToThePassword() async throws {
    let codes = try await accountWithTwoFactorOn()
    await assertThrowsAppError(try await sessions.login(username: "user1", password: password)) { XCTAssertEqual($0, .twoFactorCodeNeeded) }
    await assertThrowsAppError(try await sessions.completeTwoFactor(recoveryCode: "nope")) { XCTAssertEqual($0.fieldProblems.first?.field, "recoveryCode") }
    try await sessions.completeTwoFactor(recoveryCode: codes[0].lowercased())
    XCTAssertNotNil(sessions.state.user)
    let status = try await twoFactor.status()
    XCTAssertEqual(status.recoveryCodesLeft, 9)

    // A challenge the server no longer knows: forgotten here, and never sent twice.
    try await sessions.logout()
    await assertThrowsAppError(try await sessions.login(username: "user1", password: password)) { XCTAssertEqual($0, .twoFactorCodeNeeded) }
    fake.loginChallenges = [:]
    await assertThrowsAppError(try await sessions.completeTwoFactor(code: "654321")) { XCTAssertEqual($0, SessionRepository.challengeExpired) }
    XCTAssertNil(sessions.twoFactorChallenge)
    let sent = app.requests(to: "/auth/login/two-factor").count
    await assertThrowsAppError(try await sessions.completeTwoFactor(code: "654321")) { XCTAssertEqual($0, SessionRepository.challengeExpired) }
    XCTAssertEqual(app.requests(to: "/auth/login/two-factor").count, sent)
  }

  func testGivingUpForgetsTheWaitingSignIn() async throws {
    _ = try await accountWithTwoFactorOn()
    await assertThrowsAppError(try await sessions.login(username: "user1", password: password)) { XCTAssertEqual($0, .twoFactorCodeNeeded) }
    sessions.cancelTwoFactor()
    XCTAssertNil(sessions.twoFactorChallenge)
    await assertThrowsAppError(try await sessions.completeTwoFactor(code: "654321")) { XCTAssertEqual($0, SessionRepository.challengeExpired) }
    XCTAssertNil(sessions.state.user)
  }

  func testCheckingThePasswordWhileSignedInStillWorksWithTwoFactorOn() async throws {
    _ = try await accountWithTwoFactorOn()
    _ = try? await sessions.login(username: "user1", password: password)
    try await sessions.completeTwoFactor(code: "654321")
    let right = try await sessions.passwordIsRight(password)
    let wrong = try await sessions.passwordIsRight("not it")
    XCTAssertTrue(right, "the password step answers a challenge, not a session, and that proves the password")
    XCTAssertFalse(wrong)
    XCTAssertNil(sessions.twoFactorChallenge, "a proof leaves nothing waiting")
  }

  func testNewRecoveryCodesAndSwitchingOff() async throws {
    _ = try await accountWithTwoFactorOn()
    _ = try? await sessions.login(username: "user1", password: password)
    try await sessions.completeTwoFactor(code: "654321")
    fake.currentCode = "222222"
    let fresh = try await twoFactor.newRecoveryCodes(code: "222222")
    XCTAssertEqual(fresh.count, 10)
    await assertThrowsAppError(try await twoFactor.disable(code: "222222")) { XCTAssertEqual($0.fieldProblems.first?.field, "code", "a code works once") }
    try await twoFactor.disable(recoveryCode: fresh[3])
    let status = try await twoFactor.status()
    XCTAssertFalse(status.enabled)
  }

  func testRequiredAndNotSetUpSignsInButOnlySettingUpWorksUntilItIs() async throws {
    fake.twoFactorRequired[4] = ["group"]
    try await sessions.login(username: "user1", password: password)
    XCTAssertTrue(sessions.twoFactorSetupRequired, "said by the sign-in answer")
    let status = try await twoFactor.status()
    XCTAssertTrue(status.required); XCTAssertEqual(status.requiredBecause, ["group"])
    XCTAssertEqual(TwoFactorCode.requiredBy(status.requiredBecause), "Your group")

    _ = try await twoFactor.setup()
    _ = try await twoFactor.confirm(code: "123456")
    XCTAssertTrue(sessions.twoFactorSetupRequired, "the set-up screen stays until the recovery codes are saved")
    let left = try await twoFactor.status()
    XCTAssertEqual(left.recoveryCodesLeft, 10, "and nothing else is refused meanwhile")
    await sessions.twoFactorSetUp()
    XCTAssertFalse(sessions.twoFactorSetupRequired)
    await assertThrowsAppError(try await twoFactor.disable(recoveryCode: "x")) { XCTAssertEqual($0.conflictCondition, "required") }
  }

  func testARequirementMadeMidSessionIsNoticedFromAnyRefusal() async throws {
    try await sessions.login(username: "user1", password: password)
    XCTAssertFalse(sessions.twoFactorSetupRequired)
    fake.twoFactorRequired[4] = ["all_groups"]
    await assertThrowsAppError(try await app.container.penNames.names()) { XCTAssertEqual($0, .twoFactorSetupRequired) }
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertTrue(sessions.twoFactorSetupRequired)
    XCTAssertNotNil(sessions.state.user, "not signed out: the session is good for setting it up")
    try await sessions.logout()
    XCTAssertFalse(sessions.twoFactorSetupRequired)
  }

  func testRecoveryWithTwoFactorOnChangesThePasswordAndAsksForACode() async throws {
    try await sessions.login(username: "user1", password: password)
    let account = try XCTUnwrap(sessions.pendingRecoveryCode)
    sessions.recoveryCodeSaved()
    _ = try await twoFactor.setup()
    _ = try await twoFactor.confirm(code: "123456")
    try await sessions.logout()
    app.container.vault.clear()
    fake.currentCode = "777777"

    // Recovery does not sign anyone in past two-factor sign-in: the password is changed, and a code finishes it.
    await assertThrowsAppError(try await sessions.recover(username: "user1", recoveryCode: account, newPassword: "second-password")) {
      XCTAssertEqual($0, .twoFactorCodeNeeded)
    }
    XCTAssertNil(sessions.state.user)
    try await sessions.completeTwoFactor(code: "777777")
    XCTAssertNotNil(app.container.vault.keyPair(for: 4), "the key opens with the new password")
  }

  func testTheShapesOfTypedCodes() {
    XCTAssertTrue(TwoFactorCode.isWellFormed(" 123 456 ")); XCTAssertFalse(TwoFactorCode.isWellFormed("12345")); XCTAssertFalse(TwoFactorCode.isWellFormed("12345a"))
    XCTAssertTrue(TwoFactorCode.isRecoveryCodeShaped("abcde-12345")); XCTAssertFalse(TwoFactorCode.isRecoveryCodeShaped("abcde"))
    XCTAssertEqual(TwoFactorCode.requiredBy(["superadmins"]), "The site, for every superadmin,")
    XCTAssertEqual(TwoFactorCode.requiredBy(["all_groups", "group"]), "Your group")
  }

  func testKeysThatNeedTheServerWaitForARequiredSetUpAndAreMadeAfterIt() async throws {
    // A fresh account on an end-to-end server: no keys yet, and making them is a request the server refuses until set-up.
    fake.twoFactorRequired[4] = ["group"]
    try await sessions.login(username: "user1", password: password)
    XCTAssertTrue(sessions.twoFactorSetupRequired)
    XCTAssertEqual(app.requests(to: "/auth/keys", method: "PUT").count, 0, "not tried while it would be refused")
    XCTAssertTrue(sessions.keysLocked)
    _ = try await twoFactor.setup()
    _ = try await twoFactor.confirm(code: "123456")
    await sessions.twoFactorSetUp()
    XCTAssertEqual(app.requests(to: "/auth/keys", method: "PUT").count, 1)
    XCTAssertFalse(sessions.keysLocked, "made with the password from the sign-in")
    XCTAssertNotNil(sessions.pendingRecoveryCode)
  }

  func testKeysAlreadyInTheSignInAnswerOpenEvenBeforeARequiredSetUp() async throws {
    try await sessions.login(username: "user1", password: password) // makes the keys
    sessions.recoveryCodeSaved()
    try await sessions.logout()
    app.container.vault.clear()
    fake.twoFactorRequired[4] = ["all_groups"]
    try await sessions.login(username: "user1", password: password)
    XCTAssertTrue(sessions.twoFactorSetupRequired)
    XCTAssertFalse(sessions.keysLocked, "the bundle came with the answer; opening it needs no request")
  }

  func testAConfirmationWithoutRecoveryCodesIsNotASuccess() async throws {
    try await sessions.login(username: "user1", password: password)
    _ = try await twoFactor.setup()
    fake.intercept = { $0.path == "/auth/two-factor/confirm" ? .data(["enabled": true, "recoveryCodes": []]) : nil }
    await assertThrowsAppError(try await twoFactor.confirm(code: "123456")) {
      if case .unexpected = $0 {} else { XCTFail("\($0)") }
    }
  }

  func testARecoveryCodeIsReadAsTheServerReadsIt() async throws {
    _ = try await accountWithTwoFactorOn()
    fake.twoFactor[4]?.recoveryCodes = ["10ABC-DEF01"]
    await assertThrowsAppError(try await sessions.login(username: "user1", password: password)) { XCTAssertEqual($0, .twoFactorCodeNeeded) }
    try await sessions.completeTwoFactor(recoveryCode: "lo abc def oI")
    XCTAssertNotNil(sessions.state.user, "O for 0 and I or L for 1, as the API normalises them")
  }
}
