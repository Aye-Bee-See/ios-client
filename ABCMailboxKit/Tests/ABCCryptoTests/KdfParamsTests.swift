import ABCCrypto
import XCTest

final class KdfParamsTests: XCTestCase {

  func testDefaultJSONMatchesTheSchemaAgreedWithTheOtherClients() throws {
    // The exact example from the API README; if this changes, every client must change together.
    // Key order is not part of the contract (no JSON parser cares), so compare as objects.
    let ours = try JSONSerialization.jsonObject(with: JSONEncoder().encode(KdfParams.standard)) as? NSDictionary
    let agreed = try JSONSerialization.jsonObject(with: Data(#"{"kdf":"argon2id","alg":2,"opslimit":2,"memlimit":67108864}"#.utf8)) as? NSDictionary
    XCTAssertEqual(ours, agreed)
  }

  func testParsesWhatTheWebClientWritesWithOrWithoutTheOptionalFields() throws {
    let full = try JSONDecoder().decode(KdfParams.self, from: Data(#"{"kdf":"argon2id","alg":2,"opslimit":3,"memlimit":268435456}"#.utf8))
    XCTAssertEqual(full.opslimit, 3)
    XCTAssertEqual(full.memlimit, 268_435_456)
    let minimal = try JSONDecoder().decode(KdfParams.self, from: Data(#"{"kdf":"argon2id","somethingNew":true}"#.utf8))
    XCTAssertEqual(minimal, .standard)
  }

  func testRejectsAKdfThisClientCannotRun() {
    XCTAssertThrowsError(try JSONDecoder().decode(KdfParams.self, from: Data(#"{"kdf":"scrypt","N":1024}"#.utf8)))
  }

  func testDerivesWithItsOwnCosts() throws {
    let salt = Sodium.randomBytes(Sodium.saltBytes)
    let params = try KdfParams(opslimit: 1, memlimit: 16_777_216)
    XCTAssertEqual(try params.derive(secret: "pw", salt: salt), try Sodium.deriveKey(secret: "pw", salt: salt, opslimit: 1, memlimit: 16_777_216))
  }

  func testSecretsAreNormalisedToNFKCBeforeDerivation() throws {
    let salt = Sodium.randomBytes(Sodium.saltBytes)
    let params = try KdfParams(opslimit: 1, memlimit: 8_388_608)
    // "ä" precomposed, "a" + combining diaeresis, and the compatibility form "ﬁ" against "fi".
    XCTAssertEqual(try params.derive(secret: "\u{00E4}\u{FB01}", salt: salt), try params.derive(secret: "a\u{0308}fi", salt: salt))
  }
}
