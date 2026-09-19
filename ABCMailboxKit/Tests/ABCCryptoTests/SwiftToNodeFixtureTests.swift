import ABCCrypto
import XCTest

/// Swift to Node: writes `.build/interop/swift-fixture.json` with material made by
/// this module; `node ../tools/verify-swift-fixture.mjs` then opens it with
/// libsodium.js. Also the round-trip tests for the flows themselves.
final class SwiftToNodeFixtureTests: XCTestCase {

  func testWritesAFixtureForTheNodeVerifier() throws {
    let password = "pässword with spaces"
    let recoveryCode = SecretCodes.generate()
    let (kp, fields) = try AccountKeys.create(password: password, recoveryCode: recoveryCode)
    let group = Sodium.keypair()
    let body = "Dear Jane, greetings from the iPhone. Ünïcödé survives."
    let note = "Please print single-sided."
    let letter = try LetterCipher.encrypt(body: body, relayNote: note, readers: [
      Reader(type: Reader.user, id: 7, publicKey: fields.publicKey),
      Reader(type: Reader.chapter, id: 1, publicKey: Sodium.toBase64(group.publicKey), keyVersion: 3),
    ])
    let fileBytes = Sodium.randomBytes(2048)
    let file = try LetterCipher.encryptFile(fileBytes, contentKey: letter.contentKey)

    func wrappedJSON(_ w: WrappedKey) throws -> [String: Any] {
      ["wrapped": w.wrapped, "salt": w.salt, "params": try JSONSerialization.jsonObject(with: JSONEncoder().encode(w.params))]
    }
    let relayNote = try XCTUnwrap(letter.relayNote)
    let out: [String: Any] = [
      "password": password, "recoveryCode": recoveryCode,
      "publicKey": fields.publicKey, "privateKey": Sodium.toBase64(kp.privateKey),
      "groupPublicKey": Sodium.toBase64(group.publicKey), "groupPrivateKey": Sodium.toBase64(group.privateKey),
      "passwordWrapped": try wrappedJSON(fields.password), "recoveryWrapped": try wrappedJSON(fields.recovery),
      "letter": [
        "body": body, "note": note,
        "ciphertext": letter.body.ciphertext, "nonce": letter.body.nonce,
        "relayNote": ["ciphertext": relayNote.ciphertext, "nonce": relayNote.nonce],
        "contentKey": Sodium.toBase64(letter.contentKey),
        "envelopes": letter.envelopes.map { e -> [String: Any] in
          var o: [String: Any] = ["readerType": e.readerType, "readerId": e.readerId, "wrappedKey": e.wrappedKey]
          if let v = e.keyVersion { o["keyVersion"] = v }
          return o
        },
      ] as [String: Any],
      "file": ["plain": Sodium.toBase64(fileBytes), "ciphertext": Sodium.toBase64(file.ciphertext), "nonce": file.nonce],
      "tokenHash": ["token": recoveryCode, "sha256": SecretCodes.hashHex(recoveryCode)],
    ]
    // Tests/ABCCryptoTests/<this file> -> the package root.
    let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let dir = packageRoot.appendingPathComponent(".build/interop", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted]).write(to: dir.appendingPathComponent("swift-fixture.json"))
  }

  func testAccountKeysRoundTripAndTheSameKeypairSurvivesRewrapping() throws {
    let code = SecretCodes.generate()
    let (kp, fields) = try AccountKeys.create(password: "first password", recoveryCode: code)
    let viaPassword = try AccountKeys.unlockWithPassword(publicKey: fields.publicKey, wrapped: fields.password.wrapped, password: "first password", salt: fields.password.salt, params: fields.password.params)
    let viaCode = try AccountKeys.unlockWithCode(publicKey: fields.publicKey, wrapped: fields.recovery.wrapped, code: SecretCodes.pretty(code).lowercased(), salt: fields.recovery.salt, params: fields.recovery.params)
    XCTAssertEqual(kp.privateKey, viaPassword.privateKey)
    XCTAssertEqual(kp.privateKey, viaCode.privateKey)

    let rewrapped = try AccountKeys.wrapExisting(kp, password: "second password", recoveryCode: SecretCodes.generate())
    XCTAssertEqual(fields.publicKey, rewrapped.publicKey)
    XCTAssertNotEqual(fields.password.salt, rewrapped.password.salt)
    XCTAssertThrowsError(try AccountKeys.unlockWithPassword(publicKey: rewrapped.publicKey, wrapped: rewrapped.password.wrapped, password: "first password", salt: rewrapped.password.salt, params: rewrapped.password.params)) {
      XCTAssertTrue($0 is WrongSecretError)
    }
  }

  func testGeneratedCodesAreWellFormedAndDistinct() {
    let codes = (0..<50).map { _ in SecretCodes.generate() }
    XCTAssertTrue(codes.allSatisfy(SecretCodes.isWellFormed))
    XCTAssertEqual(Set(codes).count, 50)
    XCTAssertEqual(SecretCodes.pretty(codes[0]).count, 29) // 24 characters + 5 dashes
  }

  func testAnEditReencryptsUnderTheSameContentKeySoExistingEnvelopesStillWork() throws {
    let me = Sodium.keypair()
    let letter = try LetterCipher.encrypt(body: "first draft", relayNote: nil, readers: [Reader(type: Reader.user, id: 1, publicKey: Sodium.toBase64(me.publicKey))])
    let key = try LetterCipher.openEnvelope(letter.envelopes[0].wrappedKey, keyPair: me)
    let edited = try LetterCipher.encryptText("second draft", contentKey: key)
    XCTAssertNotEqual(letter.body.nonce, edited.nonce)
    XCTAssertEqual(try LetterCipher.decryptText(ciphertext: edited.ciphertext, nonce: edited.nonce, contentKey: LetterCipher.openEnvelope(letter.envelopes[0].wrappedKey, keyPair: me)), "second draft")
  }
}
