import ABCCrypto
import XCTest

/// Node to Swift: `node-fixture.properties` was produced by the API's own
/// `services/crypto.js` and `e2e-fixture.json` by libsodium.js (sumo build) the
/// way a browser client would. Both are the very files the Android client is
/// tested against. If these pass, an account made on the web or on Android
/// unlocks on the iPhone and a letter sealed there opens here.
final class NodeInteropTests: XCTestCase {

  private func properties() throws -> [String: String] {
    var out: [String: String] = [:]
    for line in try String(contentsOf: fixtureURL("node-fixture.properties"), encoding: .utf8).split(separator: "\n") where !line.hasPrefix("#") {
      guard let eq = line.firstIndex(of: "=") else { continue }
      out[String(line[..<eq])] = String(line[line.index(after: eq)...])
    }
    return out
  }

  func testDecryptsABodyTheServerEncrypted() throws {
    let p = try properties()
    let key = try Sodium.fromBase64(XCTUnwrap(p["contentKey"]))
    XCTAssertEqual(try LetterCipher.decryptText(ciphertext: XCTUnwrap(p["ciphertext"]), nonce: XCTUnwrap(p["nonce"]), contentKey: key), p["plaintext"])
  }

  func testOpensAContentKeyTheServerSealed() throws {
    let p = try properties()
    let kp = Sodium.KeyPair(publicKey: try Sodium.fromBase64(XCTUnwrap(p["publicKey"])), privateKey: try Sodium.fromBase64(XCTUnwrap(p["privateKey"])))
    XCTAssertEqual(Sodium.toBase64(try LetterCipher.openEnvelope(XCTUnwrap(p["sealedContentKey"]), keyPair: kp)), p["contentKey"])
  }

  private func wrapped(_ f: JSONFixture, _ name: String) throws -> (String, String, KdfParams) {
    let params = try JSONDecoder().decode(KdfParams.self, from: JSONSerialization.data(withJSONObject: f.object(name, "params")))
    return (try f.string(name, "wrapped"), try f.string(name, "salt"), params)
  }

  func testUnlocksAPrivateKeyNodeWrappedUnderAPasswordWithArgon2id() throws {
    let f = try JSONFixture("e2e-fixture.json")
    let (w, salt, params) = try wrapped(f, "passwordWrapped")
    let kp = try AccountKeys.unlockWithPassword(publicKey: f.string("publicKey"), wrapped: w, password: f.string("password"), salt: salt, params: params)
    XCTAssertEqual(Sodium.toBase64(kp.privateKey), try f.string("privateKey"))
    XCTAssertThrowsError(try AccountKeys.unlockWithPassword(publicKey: f.string("publicKey"), wrapped: w, password: "not the password", salt: salt, params: params)) {
      XCTAssertTrue($0 is WrongSecretError)
    }
  }

  func testANonASCIIPasswordTypedInDecomposedFormOpensTheSameKey() throws {
    // The fixture's password has accents, Cyrillic, and Chinese; this is the NFD spelling of it.
    // Swift's `==` on String is canonical equivalence, so compare the code points instead.
    let f = try JSONFixture("e2e-fixture.json")
    let (w, salt, params) = try wrapped(f, "passwordWrapped")
    XCTAssertNotEqual(Array(try f.string("password").unicodeScalars), Array(try f.string("passwordDecomposed").unicodeScalars))
    let kp = try AccountKeys.unlockWithPassword(publicKey: f.string("publicKey"), wrapped: w, password: f.string("passwordDecomposed"), salt: salt, params: params)
    XCTAssertEqual(Sodium.toBase64(kp.privateKey), try f.string("privateKey"))
  }

  func testARecoveryCodeTypedWithDashesAndLowerCaseOpensTheSameKey() throws {
    let f = try JSONFixture("e2e-fixture.json")
    let (w, salt, params) = try wrapped(f, "recoveryWrapped")
    let kp = try AccountKeys.unlockWithCode(publicKey: f.string("publicKey"), wrapped: w, code: f.string("recoveryCodeAsTyped"), salt: salt, params: params)
    XCTAssertEqual(Sodium.toBase64(kp.privateKey), try f.string("privateKey"))
  }

  func testOpensTheWriterAndGroupEnvelopesAndDecryptsBodyNoteAndFile() throws {
    let f = try JSONFixture("e2e-fixture.json")
    let me = Sodium.KeyPair(publicKey: try Sodium.fromBase64(f.string("publicKey")), privateKey: try Sodium.fromBase64(f.string("privateKey")))
    let group = Sodium.KeyPair(publicKey: try Sodium.fromBase64(f.string("groupPublicKey")), privateKey: try Sodium.fromBase64(f.string("groupPrivateKey")))
    let envelopes = try XCTUnwrap(f.object("letter")["envelopes"] as? [[String: Any]])
    let mine = try XCTUnwrap(envelopes.first { $0["readerType"] as? String == "user" }?["wrappedKey"] as? String)
    let theirs = try XCTUnwrap(envelopes.first { $0["readerType"] as? String == "chapter" })
    XCTAssertEqual(theirs["keyVersion"] as? Int, 1)
    let theirKey = try XCTUnwrap(theirs["wrappedKey"] as? String)

    let key = try LetterCipher.openEnvelope(mine, keyPair: me)
    XCTAssertEqual(key, try LetterCipher.openEnvelope(theirKey, keyPair: group))
    XCTAssertThrowsError(try LetterCipher.openEnvelope(theirKey, keyPair: me)) { XCTAssertTrue($0 is CannotOpenError) }

    XCTAssertEqual(try LetterCipher.decryptText(ciphertext: f.string("letter", "ciphertext"), nonce: f.string("letter", "nonce"), contentKey: key), try f.string("letter", "body"))
    XCTAssertEqual(try LetterCipher.decryptText(ciphertext: f.string("letter", "relayNote", "ciphertext"), nonce: f.string("letter", "relayNote", "nonce"), contentKey: key), try f.string("letter", "note"))
    XCTAssertEqual(try LetterCipher.decryptFile(Sodium.fromBase64(f.string("file", "ciphertext")), nonce: f.string("file", "nonce"), contentKey: key), try Sodium.fromBase64(f.string("file", "plain")))
  }

  func testOpensTheRecoveryChallengeAndHashesATokenLikeTheServerExpects() throws {
    let f = try JSONFixture("e2e-fixture.json")
    let me = Sodium.KeyPair(publicKey: try Sodium.fromBase64(f.string("publicKey")), privateKey: try Sodium.fromBase64(f.string("privateKey")))
    XCTAssertEqual(try AccountKeys.openChallenge(f.string("recovery", "sealedChallenge"), keyPair: me), try f.string("recovery", "challenge"))
    let typed = SecretCodes.pretty(try f.string("tokenHash", "token")).lowercased()
    XCTAssertEqual(SecretCodes.hashHex(typed), try f.string("tokenHash", "sha256"))
  }
}
