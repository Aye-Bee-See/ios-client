@testable import ABCCore
import ABCCrypto
import XCTest

/// The split sign-in scheme (API PR #114): the password never reaches the server. Each path against the fake API,
/// with real Argon2id, reading what was sent and checking it is never the password itself.
@MainActor
final class SplitSignInTests: XCTestCase {
  private var fake: FakeAPI!
  private var app: TestApp!
  private var sessions: SessionRepository { app.container.sessions }
  private let password = "Tomatoes by Äugust 1"

  override func setUp() async throws {
    fake = FakeAPI()
    fake.mode = "e2e"
    let fake = fake!
    app = TestApp { fake.handle($0) }
  }

  /// An account that was made the split way, with keys under the wrap key: what every account will be from the first push.
  private func splitAccount(id: Int = 4, username: String = "user1") throws -> (FakeAPI.Account, Sodium.KeyPair) {
    let (kp, split) = try AccountKeys.createSplit(password: password, recoveryCode: SecretCodes.generate())
    let f = split.fields
    let keys: [String: Any] = [
      "publicKey": f.publicKey, "wrappedPrivateKey": f.password.wrapped, "kdfSalt": f.password.salt, "kdfParams": ["kdf": "argon2id", "alg": 2, "opslimit": 2, "memlimit": 67_108_864],
      "recoveryWrappedPrivateKey": f.recovery.wrapped, "recoverySalt": f.recovery.salt, "recoveryKdfParams": ["kdf": "argon2id", "alg": 2, "opslimit": 2, "memlimit": 67_108_864],
    ]
    var a = FakeAPI.Account(id: id, username: username, password: split.authKey, keys: keys)
    a.authScheme = "split"
    return (a, kp)
  }

  private func sentPasswords() -> [String] { app.requests(to: "/auth/login", method: "POST").compactMap { $0.json["password"] as? String } }

  func testASplitAccountSignsInWithTheHandshakeAndTheAuthKeyAndOpensItsKeyWithTheWrapKey() async throws {
    let (account, kp) = try splitAccount()
    fake.accounts = [account]
    try await sessions.login(username: "user1", password: password)
    XCTAssertEqual(app.requests(to: "/auth/login-params").count, 1)
    XCTAssertEqual(sentPasswords(), [account.password], "the auth key, once")
    XCTAssertFalse(app.requests.contains { $0.bodyText.contains(password) || $0.query.values.contains { $0.contains("Tomatoes") } }, "the password is in no request, body or query")
    XCTAssertEqual(app.container.vault.keyPair(for: 4)?.privateKey, kp.privateKey, "opened with the wrap key of that sign-in")
    XCTAssertFalse(sessions.keysLocked)
    XCTAssertTrue(app.container.schemes.isKnownSplit(" User1 "), "remembered, whatever the case")
  }

  func testAnOlderAPIWithoutTheHandshakeIsPlainEverywhere() async throws {
    fake.predatesSplitAuth = true
    fake.accounts = [FakeAPI.Account(id: 4, username: "user1", password: password)]
    try await sessions.login(username: "user1", password: password)
    XCTAssertEqual(sentPasswords(), [password])
    XCTAssertFalse(app.container.schemes.isKnownSplit("user1"))
    // Keys made at that sign-in are the plain kind, and a password change stays plain.
    try await sessions.changePassword(current: password, new: "Another passphrase here")
    XCTAssertEqual(fake.accounts[0].authScheme, "plain"); XCTAssertEqual(fake.accounts[0].password, "Another passphrase here")
  }

  func testAKnownSplitNameIsNeverSignedInAsPlainWhateverTheServerSays() async throws {
    let (account, _) = try splitAccount()
    fake.accounts = [account]
    try await sessions.login(username: "user1", password: password)
    try await sessions.logout()
    // A tampered (or swapped) server: the handshake now says plain, to be sent the password itself.
    fake.accounts[0].authScheme = "plain"
    let before = app.requests(to: "/auth/login", method: "POST").count
    await assertThrowsAppError(try await sessions.login(username: "user1", password: password)) { XCTAssertEqual($0, SessionRepository.downgradeRefused("user1")) }
    XCTAssertEqual(app.requests(to: "/auth/login", method: "POST").count, before, "nothing was sent")
    XCTAssertFalse(sessions.state.isSignedIn)
  }

  func testAMalformedHandshakeIsRefusedNotReadAsPlain() async throws {
    // A 200 with no data, a "split" missing its salt and recipe, and an unknown scheme: each would, read as plain,
    // be a way to be sent the password for a name this phone does not know yet. None is.
    fake.accounts = [FakeAPI.Account(id: 4, username: "user1", password: password)]
    for answer in [Stubbed.json(["success": true, "status": 200]), .data(["scheme": "split"]), .data(["scheme": "split", "kdfSalt": "AAAAAAAAAAAAAAAAAAAAAA=="]), .data(["scheme": "argon-plus", "kdfSalt": "x", "kdfParams": ["kdf": "argon2id"]])] {
      fake.intercept = { r in r.path == "/auth/login-params" ? answer : nil }
      await assertThrowsAppError(try await sessions.login(username: "user1", password: password)) { XCTAssertEqual($0, SessionRepository.malformedHandshake) }
    }
    XCTAssertEqual(app.requests(to: "/auth/login", method: "POST").count, 0, "nothing was sent")
    // Said plainly, plain is plain.
    fake.intercept = { r in r.path == "/auth/login-params" ? .data(["scheme": "plain", "kdfSalt": "AAAAAAAAAAAAAAAAAAAAAA==", "kdfParams": ["kdf": "argon2id"]]) : nil }
    try await sessions.login(username: "user1", password: password)
    XCTAssertEqual(sentPasswords(), [password])
  }

  func testAPasswordChangeStopsWhenTheKeyCannotBeFetchedOrOpenedRatherThanLeaveItUnderTheOldPassword() async throws {
    let (account, kp) = try splitAccount()
    fake.accounts = [account]
    try await sessions.login(username: "user1", password: password)
    app.container.vault.clear() // a restored phone: signed in, no key here
    let before = fake.accounts[0].keys["wrappedPrivateKey"] as? String

    // The bundle cannot be fetched: nothing changes.
    fake.intercept = { r in r.path == "/auth/keys" && r.method == "GET" ? .error(503, info: "Try later.") : nil }
    await assertThrowsAppError(try await sessions.changePassword(current: password, new: "A different passphrase")) { XCTAssertNotEqual($0, .validation(["Your current password is incorrect."]), "the password was right; the fetch failed") }
    XCTAssertEqual(app.requests(to: "/auth/user", method: "PUT").count, 0)
    XCTAssertEqual(fake.accounts[0].password, account.password)

    // The bundle has a key the current password does not open (tampered, or another device's): nothing changes.
    fake.accounts[0].keys["wrappedPrivateKey"] = try AccountKeys.wrapForSplitPassword(Sodium.keypair(), password: "someone else's").wrapped.wrapped
    await assertThrowsAppError(try await sessions.changePassword(current: password, new: "A different passphrase")) { XCTAssertTrue($0.userMessage?.contains("was not changed") == true) }
    XCTAssertEqual(app.requests(to: "/auth/user", method: "PUT").count, 0)
    fake.accounts[0].keys["wrappedPrivateKey"] = before

    // Fetched and opened: the change re-wraps the same key.
    try await sessions.changePassword(current: password, new: "A different passphrase")
    let again = try SplitAuth.derive(password: "A different passphrase", salt: Sodium.fromBase64(fake.accounts[0].keys["kdfSalt"] as! String))
    XCTAssertEqual(try AccountKeys.unlockWithWrapKey(publicKey: account.keys["publicKey"] as! String, wrapped: fake.accounts[0].keys["wrappedPrivateKey"] as! String, wrapKey: again.wrapKey).privateKey, kp.privateKey)
  }

  func testUnderTheFlagThePasswordIsNeverSentOnTheAppsOwnAndAnAccountFromBeforeSignsInOnlyByThePersonsChoice() async throws {
    fake.requireSplitAuth = true
    fake.accounts = [FakeAPI.Account(id: 4, username: "olduser", password: password)]
    // The handshake calls every name split. The auth key is refused, and that is the end of it: no fallback (API PR #117, item 23).
    await assertThrowsAppError(try await sessions.login(username: "olduser", password: password)) { XCTAssertTrue($0.isUnauthorized) }
    XCTAssertEqual(sentPasswords().map(\.count), [44], "one request, and not the password")

    // The person's explicit choice sends the password as it is, once, and the session remembers the way.
    try await sessions.login(username: "olduser", password: password, olderAccount: true)
    XCTAssertEqual(sentPasswords().last, password)
    XCTAssertTrue(sessions.state.session?.olderAccount == true)
    XCTAssertFalse(app.container.schemes.isKnownSplit("olduser"), "not a split sign-in")
    XCTAssertNotNil(app.container.vault.keyPair(for: 4), "keys were made at that sign-in, plain, under the password")
    let key = try Data(XCTUnwrap(app.container.vault.keyPair(for: 4)).privateKey)
    let k = fake.accounts[0].keys
    _ = try AccountKeys.unlockWithPassword(publicKey: k["publicKey"] as! String, wrapped: k["wrappedPrivateKey"] as! String, password: password, salt: k["kdfSalt"] as! String, params: .standard)

    // A later proof goes the same way: unlocking on a phone without the key, and proving for a change.
    app.container.vault.clear()
    let before = sentPasswords().count
    try await sessions.unlock(password: password)
    XCTAssertEqual(app.container.vault.keyPair(for: 4)?.privateKey, key); XCTAssertEqual(sentPasswords().count, before, "unlocking sends nothing")
    try await sessions.changePassword(current: password, new: "A different passphrase")
    XCTAssertEqual(sentPasswords()[before], password, "the proof, by the remembered choice")
    XCTAssertEqual(fake.accounts[0].authScheme, "split", "moved to split by the change")
    XCTAssertFalse(sessions.state.session?.olderAccount == true, "and no longer an account from before")
    XCTAssertTrue(app.container.schemes.isKnownSplit("olduser"))
    // The stored session is read back with the flag, and a session stored before the flag existed reads as false.
    XCTAssertEqual(try JSONDecoder().decode(Session.self, from: Data(#"{"token":"t","expiresAtMillis":1,"user":{"id":4,"username":"olduser","role":"user"}}"#.utf8)).olderAccount, false)

    // The choice is refused for a name this phone knows as split, and nothing is sent.
    try await sessions.logout()
    let count = sentPasswords().count
    await assertThrowsAppError(try await sessions.login(username: "olduser", password: "A different passphrase", olderAccount: true)) { XCTAssertEqual($0, SessionRepository.downgradeRefused("olduser")) }
    XCTAssertEqual(sentPasswords().count, count)
    // And the ordinary way now works with one derivation.
    try await sessions.login(username: "olduser", password: "A different passphrase")
    XCTAssertEqual(sentPasswords().last?.count, 44)
  }

  func testASplitAccountWithNoKeysYetGetsThemUnderTheWrapKeyOfThatSignInWithTheSameSalt() async throws {
    // Made by an admin (a chapter member): a split password with a salt and no keys. The keys come at first sign-in.
    let salt = Sodium.randomBytes(Sodium.saltBytes)
    let keys = try SplitAuth.derive(password: password, salt: salt)
    var a = FakeAPI.Account(id: 9, username: "member1", password: keys.authKeyBase64, role: "chapter", chapterId: 1, keys: ["kdfSalt": Sodium.toBase64(salt), "kdfParams": ["kdf": "argon2id", "alg": 2, "opslimit": 2, "memlimit": 67_108_864]])
    a.authScheme = "split"
    fake.accounts = [a]
    try await sessions.login(username: "member1", password: password)
    XCTAssertEqual(sentPasswords(), [keys.authKeyBase64])
    let code = try XCTUnwrap(sessions.pendingRecoveryCode)
    let k = fake.accounts[0].keys
    XCTAssertEqual(k["kdfSalt"] as? String, Sodium.toBase64(salt), "the sign-in's own salt, so the one derivation keeps opening both")
    let mine = try XCTUnwrap(app.container.vault.keyPair(for: 9))
    let minePrivate = Data(mine.privateKey) // a copy: signing out wipes the one everybody holds
    XCTAssertEqual(try AccountKeys.unlockWithWrapKey(publicKey: k["publicKey"] as! String, wrapped: k["wrappedPrivateKey"] as! String, wrapKey: keys.wrapKey).privateKey, mine.privateKey)
    XCTAssertEqual(try AccountKeys.unlockWithCode(publicKey: k["publicKey"] as! String, wrapped: k["recoveryWrappedPrivateKey"] as! String, code: code, salt: k["recoverySalt"] as! String, params: .standard).privateKey, mine.privateKey)
    // And the next sign-in is one request that opens the same key.
    sessions.recoveryCodeSaved()
    try await sessions.logout()
    try await sessions.login(username: "member1", password: password)
    XCTAssertEqual(sentPasswords().count, 2); XCTAssertEqual(app.container.vault.keyPair(for: 9)?.privateKey, minePrivate)
  }

  func testClaimingSendsTheAuthKeyAndTheKeysRewrappedUnderTheWrapKeyAndThePasswordIsNowhere() async throws {
    fake.requireSplitAuth = true
    fake.accounts = [FakeAPI.Account(id: 9, username: "member1", password: "unused", role: "chapter", chapterId: 1)]
    let writer = Sodium.keypair()
    let made = try GroupKeys.claimToken(writerPrivateKey: writer.privateKey)
    fake.accounts.append(FakeAPI.Account(id: 47, username: "managed-47", password: "unknowable", managedBy: 1,
      keys: ["publicKey": Sodium.toBase64(writer.publicKey)], orgWrappedPrivateKey: "sealed-to-group",
      claim: ["tokenHash": made.tokenHash, "claimWrappedPrivateKey": made.wrapped.wrapped, "claimSalt": made.wrapped.salt, "claimKdfParams": ["kdf": "argon2id", "alg": 2, "opslimit": 2, "memlimit": 67_108_864]], name: "Alex"))
    _ = try await sessions.claimInfo(token: made.token)
    try await sessions.claim(token: made.token, username: "alex", password: password, email: nil)

    let sent = try XCTUnwrap(app.requests(to: "/auth/claim", method: "POST").first)
    XCTAssertEqual(sent.json["authScheme"] as? String, "split"); XCTAssertEqual((sent.json["password"] as? String)?.count, 44)
    XCTAssertNotNil(sent.json["wrappedPrivateKey"]); XCTAssertNotNil(sent.json["kdfSalt"]); XCTAssertNotNil(sent.json["recoveryWrappedPrivateKey"])
    XCTAssertFalse(app.requests.contains { $0.bodyText.contains(password) }, "the password is in no request, the claim included")
    XCTAssertEqual(fake.accounts[1].authScheme, "split")
    XCTAssertEqual(sessions.state.user?.id, 47)
    XCTAssertEqual(app.container.vault.keyPair(for: 47)?.privateKey, writer.privateKey, "the very same key, now under the wrap key")
    XCTAssertEqual(sentPasswords().count, 1, "signed in after the claim with the auth key, first time")
    XCTAssertTrue(app.container.schemes.isKnownSplit("alex"))
    // The recovery code still opens it: that wrap is the plain kind.
    let code = try XCTUnwrap(sessions.pendingRecoveryCode)
    let k = fake.accounts[1].keys
    XCTAssertEqual(try AccountKeys.unlockWithCode(publicKey: k["publicKey"] as! String, wrapped: k["recoveryWrappedPrivateKey"] as! String, code: code, salt: k["recoverySalt"] as! String, params: .standard).privateKey, writer.privateKey)
  }

  func testChangingThePasswordOfASplitAccountProvesTheOldOneWithItsAuthKeyAndRewrapsUnderANewSalt() async throws {
    let (account, kp) = try splitAccount()
    fake.accounts = [account]
    try await sessions.login(username: "user1", password: password)
    let oldSalt = fake.accounts[0].keys["kdfSalt"] as? String
    await assertThrowsAppError(try await sessions.changePassword(current: "not it", new: "A different passphrase")) { XCTAssertEqual($0, .validation(["Your current password is incorrect."])) }
    try await sessions.changePassword(current: password, new: "A different passphrase")
    let put = try XCTUnwrap(app.requests(to: "/auth/user", method: "PUT").last)
    XCTAssertEqual(put.json["authScheme"] as? String, "split"); XCTAssertEqual((put.json["password"] as? String)?.count, 44)
    XCTAssertNotEqual(fake.accounts[0].keys["kdfSalt"] as? String, oldSalt, "a fresh salt with the new password")
    XCTAssertFalse(app.requests.contains { $0.bodyText.contains(password) || $0.bodyText.contains("A different passphrase") })
    let again = try SplitAuth.derive(password: "A different passphrase", salt: Sodium.fromBase64(fake.accounts[0].keys["kdfSalt"] as! String))
    XCTAssertEqual(try AccountKeys.unlockWithWrapKey(publicKey: account.keys["publicKey"] as! String, wrapped: fake.accounts[0].keys["wrappedPrivateKey"] as! String, wrapKey: again.wrapKey).privateKey, kp.privateKey)
  }

  func testDeletingASplitAccountProvesAndSendsTheAuthKeyNotThePassword() async throws {
    let (account, _) = try splitAccount()
    fake.accounts = [account]
    try await sessions.login(username: "user1", password: password)
    await assertThrowsAppError(try await app.container.accountDeletion.deleteMyAccount(password: "not it")) { XCTAssertEqual($0, AccountDeletion.wrongPassword) }
    XCTAssertEqual(app.requests(to: "/auth/user", method: "DELETE").count, 0)
    try await app.container.accountDeletion.deleteMyAccount(password: password)
    let delete = try XCTUnwrap(app.requests(to: "/auth/user", method: "DELETE").first)
    XCTAssertEqual(delete.json["password"] as? String, account.password)
    XCTAssertFalse(app.requests.contains { $0.bodyText.contains(password) })
    XCTAssertFalse(sessions.state.isSignedIn)
  }

  func testAWrongPasswordForAKnownSplitNameIsOneRefusal() async throws {
    fake.requireSplitAuth = true
    let (account, _) = try splitAccount(id: 5, username: "newuser")
    fake.accounts = [account]
    try await sessions.login(username: "newuser", password: password)
    try await sessions.logout()
    let before = sentPasswords().count
    await assertThrowsAppError(try await sessions.login(username: "newuser", password: "not it")) { XCTAssertTrue($0.isUnauthorized) }
    XCTAssertEqual(sentPasswords().count, before + 1); XCTAssertEqual(sentPasswords().last?.count, 44)
  }

  func testUnlockingOnAPhoneWithoutTheKeyUsesTheWrapKey() async throws {
    let (account, kp) = try splitAccount()
    fake.accounts = [account]
    try await sessions.login(username: "user1", password: password)
    app.container.vault.clear()
    XCTAssertTrue(sessions.keysLocked)
    await assertThrowsAppError(try await sessions.unlock(password: "not it")) { XCTAssertEqual($0, .validation(["That password does not open your letters."])) }
    try await sessions.unlock(password: password)
    XCTAssertEqual(app.container.vault.keyPair(for: 4)?.privateKey, kp.privateKey)
    XCTAssertFalse(app.requests.contains { $0.bodyText.contains(password) })
  }

  func testThePasswordRulesAreTheAppsNow() {
    XCTAssertFalse(PasswordRules.isLongEnough("short one")); XCTAssertTrue(PasswordRules.isLongEnough("ten chars!"))
    XCTAssertEqual(PasswordRules.strength("aaaaaaaaaa"), .weak)
    XCTAssertEqual(PasswordRules.strength("1234567890"), .weak)
    XCTAssertEqual(PasswordRules.strength("tomatoes12"), .fair)
    XCTAssertEqual(PasswordRules.strength("Tomatoes12"), .good)
    XCTAssertEqual(PasswordRules.strength("correct horse battery staple"), .good, "four words with spaces score as a passphrase")
    XCTAssertEqual(PasswordRules.strength("correct horse battery staple again"), .strong)
    XCTAssertEqual(PasswordRules.strength("Tr0ub4dor&3xyz"), .strong)
    XCTAssertEqual(PasswordRules.Strength.strong.bars, 4)
  }
}
