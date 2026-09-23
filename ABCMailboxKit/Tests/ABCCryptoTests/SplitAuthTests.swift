@testable import ABCCrypto
import XCTest

final class SplitAuthTests: XCTestCase {
  /// The vector from the API's `test/auth-split.test.js` and the proposal: master = bytes 00…1f.
  private let master = Data((0..<32).map { UInt8($0) })

  func testTheTwoDerivationsMatchTheAPIsVectorByteForByte() throws {
    XCTAssertEqual(Sodium.toBase64(master), "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=")
    let keys = try SplitAuth.fromMaster(master)
    XCTAssertEqual(Sodium.toBase64(keys.wrapKey), "NFKvOp5duAjQ7QmoxriVlK2aftNJI7xkGi/wooDCMcI=")
    XCTAssertEqual(keys.authKeyBase64, "wjrINHoPKZiRPnOiURiE/mvNm6+UZXEkNDE/lgfPOWo=")
    XCTAssertEqual(keys.authKeyBase64.count, 44, "44 characters of standard base64 with padding")
    XCTAssertTrue(SplitAuth.looksLikeAuthKey(keys.authKeyBase64)); XCTAssertFalse(SplitAuth.looksLikeAuthKey("correct horse battery staple"))
    keys.wipe()
    XCTAssertEqual(keys.wrapKey, Data(repeating: 0, count: 32)); XCTAssertEqual(keys.authKey, Data(repeating: 0, count: 32))
  }

  func testFromAPasswordTheSameSaltAndRecipeGiveTheSameKeysAndAWrongPasswordOpensNothing() throws {
    let salt = Sodium.randomBytes(Sodium.saltBytes)
    let a = try SplitAuth.derive(password: "Tomatoes by Äugust", salt: salt), b = try SplitAuth.derive(password: "Tomatoes by A\u{308}ugust", salt: salt) // NFKC: the same password
    XCTAssertEqual(a.wrapKey, b.wrapKey); XCTAssertEqual(a.authKeyBase64, b.authKeyBase64)
    XCTAssertNotEqual(a.wrapKey, a.authKey, "the two keys are unrelated")

    let kp = Sodium.keypair()
    let (wrapped, authKey) = try AccountKeys.wrapForSplitPassword(kp, password: "Tomatoes by Äugust")
    XCTAssertEqual(authKey.count, 44)
    let again = try SplitAuth.derive(password: "Tomatoes by Äugust", salt: Sodium.fromBase64(wrapped.salt), params: wrapped.params)
    XCTAssertEqual(try AccountKeys.unlockWithWrapKey(publicKey: Sodium.toBase64(kp.publicKey), wrapped: wrapped.wrapped, wrapKey: again.wrapKey).privateKey, kp.privateKey)
    let wrong = try SplitAuth.derive(password: "tomatoes by august", salt: Sodium.fromBase64(wrapped.salt), params: wrapped.params)
    XCTAssertThrowsError(try AccountKeys.unlockWithWrapKey(publicKey: Sodium.toBase64(kp.publicKey), wrapped: wrapped.wrapped, wrapKey: wrong.wrapKey)) { XCTAssertTrue($0 is WrongSecretError) }
    // And the auth key is not the wrap key: a server holding the auth key cannot open the box.
    XCTAssertThrowsError(try KeyWrapping.unwrapWithKey(wrapped.wrapped, key: again.authKey)) { XCTAssertTrue($0 is WrongSecretError) }
    // Nor does the old plain unwrap, which derives the master key itself and uses it directly.
    XCTAssertThrowsError(try KeyWrapping.unwrap(wrapped.wrapped, secret: "Tomatoes by Äugust", salt: wrapped.salt, params: wrapped.params))
  }

  func testASplitAccountsRecoveryWrapIsThePlainKindOpenedByTheCodeItself() throws {
    let (kp, split) = try AccountKeys.createSplit(password: "Tomatoes by August", recoveryCode: "ABCD-EFGH-JKLM-NPQR-STUV-WXYZ")
    let r = split.fields.recovery
    XCTAssertEqual(try AccountKeys.unlockWithCode(publicKey: split.fields.publicKey, wrapped: r.wrapped, code: "abcd efgh jklm npqr stuv wxyz", salt: r.salt, params: r.params).privateKey, kp.privateKey)
    // Keys made under a sign-in's wrap key keep that sign-in's salt, so the same derivation opens them next time.
    let salt = Sodium.randomBytes(Sodium.saltBytes)
    let keys = try SplitAuth.derive(password: "Tomatoes by August", salt: salt)
    let (kp2, fields) = try AccountKeys.createUnderWrapKey(keys.wrapKey, salt: Sodium.toBase64(salt), params: .standard, recoveryCode: SecretCodes.generate())
    XCTAssertEqual(fields.password.salt, Sodium.toBase64(salt))
    XCTAssertEqual(try AccountKeys.unlockWithWrapKey(publicKey: fields.publicKey, wrapped: fields.password.wrapped, wrapKey: keys.wrapKey).privateKey, kp2.privateKey)
  }

  func testTheContextMustBeEightASCIICharacters() {
    XCTAssertThrowsError(try Sodium.deriveSubkey(masterKey: master, id: 1, context: "abc"))
    XCTAssertThrowsError(try Sodium.deriveSubkey(masterKey: master, id: 1, context: "abcwräp_"))
    XCTAssertThrowsError(try Sodium.deriveSubkey(masterKey: Data(repeating: 1, count: 16), id: 1, context: "abcwrap_"))
  }
}
