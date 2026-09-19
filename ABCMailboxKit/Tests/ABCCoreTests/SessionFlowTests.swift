@testable import ABCCore
import ABCCrypto
import XCTest

/// Whole account flows against the fake API, with real Argon2id and real sealed boxes.
@MainActor
final class SessionFlowTests: XCTestCase {
  private var fake: FakeAPI!
  private var app: TestApp!
  private var sessions: SessionRepository { app.container.sessions }

  override func setUp() async throws {
    fake = FakeAPI()
    fake.accounts = [FakeAPI.Account(id: 4, username: "user1", password: "pässword1")]
    let fake = fake!
    app = TestApp { fake.handle($0) }
  }

  func testKeysAreMadeAtSignInWhileTheServerIsStillInServerMode() async throws {
    // API PR #95: the move to end-to-end does not wait for anyone. Keys appear as people sign in.
    fake.mode = "server"
    fake.messages = [["id": 1, "chat": 7, "user": 4, "sender": "user", "prisoner": 3, "messageText": "An earlier letter."]]
    let session = try await sessions.login(username: " user1 ", password: "pässword1")
    XCTAssertEqual(session.user.username, "user1")
    XCTAssertEqual(app.requests(to: "/auth/login").first?.json["username"] as? String, "user1", "the username is trimmed")

    // A server-mode sign-in answer carries no key bundle, so the app asks, finds none, and makes them.
    XCTAssertEqual(app.requests(to: "/auth/keys").map(\.method), ["GET", "PUT"])
    let code = try XCTUnwrap(sessions.pendingRecoveryCode, "the recovery code is shown, and cannot be skipped")
    let k = fake.accounts[0].keys
    XCTAssertEqual(Set(k.keys), ["publicKey", "wrappedPrivateKey", "kdfSalt", "kdfParams", "recoveryWrappedPrivateKey", "recoverySalt", "recoveryKdfParams"], "the whole bundle in one request")
    let viaCode = try AccountKeys.unlockWithCode(publicKey: k["publicKey"] as! String, wrapped: k["recoveryWrappedPrivateKey"] as! String, code: code, salt: k["recoverySalt"] as! String, params: .standard)
    XCTAssertEqual(viaCode.privateKey, app.container.vault.keyPair(for: 4)?.privateKey)
    XCTAssertFalse(sessions.keysLocked, "nothing is ever locked in server mode: the server still reads for everyone")

    // The next sign-in finds the keys and opens them; no second recovery code.
    sessions.recoveryCodeSaved()
    try await sessions.logout()
    try await sessions.login(username: "user1", password: "pässword1")
    XCTAssertNil(sessions.pendingRecoveryCode)
    XCTAssertEqual(app.container.vault.keyPair(for: 4)?.privateKey, viaCode.privateKey)
    XCTAssertEqual(app.requests(to: "/auth/keys", method: "PUT").count, 1)
  }

  func testAPasswordChangeInServerModeRewrapsTheKeyTooEvenFromAPhoneThatDoesNotHoldIt() async throws {
    fake.mode = "server"
    try await sessions.login(username: "user1", password: "pässword1")
    let key = try XCTUnwrap(app.container.vault.keyPair(for: 4)).privateKey
    app.container.vault.clear() // a restored phone: signed in, no key here
    try await sessions.changePassword(current: "pässword1", new: "new-password")
    let k = fake.accounts[0].keys
    let reopened = try AccountKeys.unlockWithPassword(publicKey: k["publicKey"] as! String, wrapped: k["wrappedPrivateKey"] as! String, password: "new-password", salt: k["kdfSalt"] as! String, params: .standard)
    XCTAssertEqual(reopened.privateKey, key, "otherwise the key would stay under the old password and be lost at the switch")
  }

  func testAnAdminNeverGetsKeys() async throws {
    fake.accounts.append(FakeAPI.Account(id: 1, username: "admin", password: "abcpassword", role: "admin"))
    try await sessions.login(username: "admin", password: "abcpassword")
    XCTAssertEqual(app.requests(to: "/auth/keys").count, 0)
    XCTAssertNil(sessions.pendingRecoveryCode)
  }

  func testAWrongPasswordIsARefusalNotASession() async {
    await assertThrowsAppError(try await sessions.login(username: "user1", password: "nope")) { XCTAssertTrue($0.isUnauthorized) }
    XCTAssertFalse(sessions.state.isSignedIn)
    XCTAssertEqual(sessions.expiredCount, 0)
  }

  func testFirstSignInOnAnEndToEndServerMakesKeysAndARecoveryCodeBothOfWhichOpenTheSameKey() async throws {
    try await sessions.login(username: "user1", password: "pässword1")
    let code = try XCTUnwrap(sessions.pendingRecoveryCode)
    XCTAssertTrue(SecretCodes.isWellFormed(code))
    XCTAssertFalse(sessions.keysLocked)

    // What reached the server: a public key and two wrapped copies, never the private key or the code.
    let sent = try XCTUnwrap(app.requests(to: "/auth/keys", method: "PUT").first)
    XCTAssertEqual(Set(sent.json.keys), ["publicKey", "wrappedPrivateKey", "kdfSalt", "kdfParams", "recoveryWrappedPrivateKey", "recoverySalt", "recoveryKdfParams"])
    XCTAssertFalse(sent.bodyText.contains(code))
    let mine = try XCTUnwrap(app.container.vault.keyPair(for: 4))
    XCTAssertFalse(sent.bodyText.contains(Sodium.toBase64(mine.privateKey)))

    let k = fake.accounts[0].keys
    let viaPassword = try AccountKeys.unlockWithPassword(publicKey: k["publicKey"] as! String, wrapped: k["wrappedPrivateKey"] as! String, password: "pässword1", salt: k["kdfSalt"] as! String, params: .standard)
    let viaCode = try AccountKeys.unlockWithCode(publicKey: k["publicKey"] as! String, wrapped: k["recoveryWrappedPrivateKey"] as! String, code: code, salt: k["recoverySalt"] as! String, params: .standard)
    XCTAssertEqual(viaPassword.privateKey, mine.privateKey)
    XCTAssertEqual(viaCode.privateKey, mine.privateKey)

    sessions.recoveryCodeSaved()
    XCTAssertNil(sessions.pendingRecoveryCode)
  }

  func testTheNextSignInUnlocksTheSameKeyAndARelaunchKeepsItUnlocked() async throws {
    try await sessions.login(username: "user1", password: "pässword1")
    let first = try XCTUnwrap(app.container.vault.keyPair(for: 4)).privateKey
    try await sessions.logout()
    XCTAssertNil(app.container.vault.keyPair(for: 4))
    XCTAssertFalse(sessions.state.isSignedIn)

    try await sessions.login(username: "user1", password: "pässword1")
    XCTAssertNil(sessions.pendingRecoveryCode, "keys exist already; no new recovery code")
    XCTAssertEqual(app.container.vault.keyPair(for: 4)?.privateKey, first)

    // A second launch: same Keychain, new process. Signed in and unlocked before any request.
    let fake = fake!
    let relaunched = TestApp(secrets: app.secrets) { fake.handle($0) }
    XCTAssertEqual(relaunched.container.sessions.state.user?.id, 4)
    XCTAssertEqual(relaunched.container.vault.keyPair(for: 4)?.privateKey, first)
    await relaunched.container.modes.refresh()
    XCTAssertFalse(relaunched.container.sessions.keysLocked)
  }

  func testAPhoneWithoutTheKeyIsLockedUntilThePasswordOpensIt() async throws {
    try await sessions.login(username: "user1", password: "pässword1")
    app.container.vault.clear() // as after a restore: the session survived, the key did not
    XCTAssertTrue(sessions.keysLocked)
    await assertThrowsAppError(try await sessions.unlock(password: "wrong")) { XCTAssertEqual($0, .validation(["That password does not open your letters."])) }
    XCTAssertTrue(sessions.keysLocked)
    try await sessions.unlock(password: "pässword1")
    XCTAssertFalse(sessions.keysLocked)
  }

  func testChangingThePasswordChecksTheOldOneRewrapsTheSameKeyAndAdoptsTheFreshToken() async throws {
    try await sessions.login(username: "user1", password: "pässword1")
    let key = try XCTUnwrap(app.container.vault.keyPair(for: 4)).privateKey
    let oldToken = try XCTUnwrap(sessions.state.session?.token)

    await assertThrowsAppError(try await sessions.changePassword(current: "typo", new: "new-password")) { XCTAssertEqual($0, .validation(["Your current password is incorrect."])) }
    XCTAssertTrue(sessions.state.isSignedIn, "a typo in the current password must not sign anyone out")

    try await sessions.changePassword(current: "pässword1", new: "new-password")
    let newToken = try XCTUnwrap(sessions.state.session?.token)
    XCTAssertNotEqual(newToken, oldToken)
    XCTAssertNil(fake.tokens[oldToken], "every older session is ended")
    let k = fake.accounts[0].keys
    let reopened = try AccountKeys.unlockWithPassword(publicKey: k["publicKey"] as! String, wrapped: k["wrappedPrivateKey"] as! String, password: "new-password", salt: k["kdfSalt"] as! String, params: .standard)
    XCTAssertEqual(reopened.privateKey, key)
  }

  func testRecoveryWithTheCodeProvesPossessionSetsANewPasswordAndKeepsTheKey() async throws {
    try await sessions.login(username: "user1", password: "pässword1")
    let code = try XCTUnwrap(sessions.pendingRecoveryCode)
    let key = try XCTUnwrap(app.container.vault.keyPair(for: 4)).privateKey
    try await sessions.logout()

    await assertThrowsAppError(try await sessions.recover(username: "user1", recoveryCode: SecretCodes.generate(), newPassword: "second-password")) {
      XCTAssertEqual($0, .validation(["That recovery code does not match this account. Check it against the copy you saved."]))
    }
    // Typed the way people type: lower case, with dashes.
    try await sessions.recover(username: "user1", recoveryCode: SecretCodes.pretty(code).lowercased(), newPassword: "second-password")
    XCTAssertEqual(sessions.state.user?.id, 4)
    XCTAssertEqual(app.container.vault.keyPair(for: 4)?.privateKey, key)
    XCTAssertEqual(fake.accounts[0].password, "second-password")
    XCTAssertFalse(try XCTUnwrap(app.requests(to: "/auth/recover", method: "POST").first).bodyText.contains(code))
  }

  func testClaimingOpensTheGroupMadeKeyWithTheTokenAndRewrapsTheVerySameKey() async throws {
    // A group made this writer's keypair and a claim token for it.
    let writer = Sodium.keypair()
    let made = try GroupKeys.claimToken(writerPrivateKey: writer.privateKey)
    fake.accounts.append(FakeAPI.Account(id: 47, username: "managed-47", password: "unknowable", managedBy: 1,
      keys: ["publicKey": Sodium.toBase64(writer.publicKey)], orgWrappedPrivateKey: "sealed-to-group",
      claim: ["tokenHash": made.tokenHash, "claimWrappedPrivateKey": made.wrapped.wrapped, "claimSalt": made.wrapped.salt, "claimKdfParams": ["kdf": "argon2id", "alg": 2, "opslimit": 2, "memlimit": 67_108_864]], name: "Alex"))

    let info = try await sessions.claimInfo(token: made.token)
    XCTAssertEqual(info.writerName, "Alex"); XCTAssertEqual(info.groupName, "Test Chapter"); XCTAssertTrue(info.endToEnd)

    try await sessions.claim(token: made.token, username: "alex", password: "my own password", email: "  ")
    XCTAssertEqual(sessions.state.user?.id, 47)
    XCTAssertEqual(app.container.vault.keyPair(for: 47)?.privateKey, writer.privateKey, "earlier letters stay readable: the keypair did not change")
    XCTAssertTrue(SecretCodes.isWellFormed(try XCTUnwrap(sessions.pendingRecoveryCode)))
    XCTAssertEqual(app.requests(to: "/auth/claim", method: "GET").count, 1, "claim checks are rate limited: the check's answer is reused")
    let sent = try XCTUnwrap(app.requests(to: "/auth/claim", method: "POST").first).json
    XCTAssertNil(sent["email"], "a blank email is left out")
    XCTAssertNotNil(sent["recoveryWrappedPrivateKey"])
    XCTAssertNil(fake.accounts[1].orgWrappedPrivateKey)
  }

  func testARefusedTokenSignsOutOnceAndAStaleReportIsIgnored() async throws {
    fake.mode = "server"
    try await sessions.login(username: "user1", password: "pässword1")
    let token = try XCTUnwrap(sessions.state.session?.token)
    fake.tokens[token] = nil // revoked on the server

    await assertThrowsAppError(try await app.container.sessions.unlock(password: "x")) { XCTAssertTrue($0.isUnauthorized) }
    for _ in 0..<50 where sessions.state.isSignedIn { try await Task.sleep(nanoseconds: 10_000_000) }
    XCTAssertFalse(sessions.state.isSignedIn)
    XCTAssertEqual(sessions.expiredCount, 1)
    XCTAssertNil(app.secrets.read("session"))
  }

  func testSigningOutClearsTheDeviceEvenWhenTheServerCannotBeTold() async throws {
    fake.mode = "server"
    try await sessions.login(username: "user1", password: "pässword1")
    fake.intercept = { $0.path == "/auth/logout" ? .error(503, info: "Down for maintenance.") : nil }
    await assertThrowsAppError(try await sessions.logout(everywhere: true))
    XCTAssertFalse(sessions.state.isSignedIn)
    XCTAssertNil(app.secrets.read("session"))
    XCTAssertEqual(app.requests(to: "/auth/logout").first?.json["everywhere"] as? Bool, true)
  }

  func testAReinstallDoesNotInheritTheLastInstallsKeychain() async throws {
    try await sessions.login(username: "user1", password: "pässword1")
    XCTAssertNotNil(app.secrets.read("session"))
    // Deleting the app takes UserDefaults with it and leaves the Keychain behind.
    let fake = fake!
    let (configuration, _) = StubServer.configuration { fake.handle($0) }
    let fresh = UserDefaults(suiteName: "abc-tests-\(UUID().uuidString)")!
    let reinstalled = AppContainer(defaultBaseURL: URL(string: "http://api.test/")!, secrets: app.secrets, defaults: fresh, configuration: configuration, files: LocalFiles(root: app.scratch), draftsDirectory: app.scratch, offlineDirectory: app.scratch, outboxDirectory: app.scratch.appendingPathComponent("outbox"))
    XCTAssertFalse(reinstalled.sessions.state.isSignedIn)
    XCTAssertNil(app.secrets.read("key_vault"))
  }

  func testChangingTheDeveloperServerSignsOutAndAsksTheNewServerItsMode() async throws {
    fake.mode = "server"
    try await sessions.login(username: "user1", password: "pässword1")
    await app.container.modes.refresh()
    XCTAssertEqual(app.container.modes.mode, .server)
    fake.mode = "e2e"
    let saved = try await app.container.devServer.set("192.168.1.20")
    XCTAssertEqual(saved, "http://192.168.1.20:3000/")
    XCTAssertTrue(app.container.devServer.isOverridden)
    XCTAssertFalse(sessions.state.isSignedIn, "a token is only good for the server that issued it")
    XCTAssertEqual(app.container.modes.mode, .e2e)
    let health = try await app.container.devServer.check()
    XCTAssertEqual(health, "ok, e2e mode")
    await app.container.devServer.reset()
    XCTAssertFalse(app.container.devServer.isOverridden)
    do { _ = try await app.container.devServer.set("not a url at all"); XCTFail("expected a refusal") } catch { XCTAssertTrue(error is DevServerRepository.InvalidURL) }
  }
}
