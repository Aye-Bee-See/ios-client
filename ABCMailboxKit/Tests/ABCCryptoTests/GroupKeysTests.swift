import ABCCrypto
import XCTest

final class GroupKeysTests: XCTestCase {

  func testAPublicKeyCanBeRecomputedFromItsPrivateKey() throws {
    let kp = Sodium.keypair()
    XCTAssertEqual(kp.publicKey, try Sodium.publicKey(of: kp.privateKey))
  }

  func testAGroupKeyMadeForTheFirstMemberOpensForThemAndCanBeHandedToASecond() throws {
    let first = Sodium.keypair(), second = Sodium.keypair()
    let group = try GroupKeys.createSealed(to: Sodium.toBase64(first.publicKey))
    let opened = try GroupKeys.open(group.sealedPrivateKey, holder: first, expectedPublicKey: group.publicKey)
    XCTAssertEqual(group.keyPair.privateKey, opened.privateKey)

    let forSecond = try GroupKeys.sealPrivateKey(opened.privateKey, to: Sodium.toBase64(second.publicKey))
    XCTAssertEqual(group.keyPair.privateKey, try GroupKeys.open(forSecond, holder: second, expectedPublicKey: group.publicKey).privateKey)
    XCTAssertThrowsError(try GroupKeys.open(forSecond, holder: first, expectedPublicKey: group.publicKey)) { XCTAssertTrue($0 is CannotOpenError) }
  }

  func testAKeyThatDoesNotMatchThePublishedPublicKeyIsRefused() throws {
    let member = Sodium.keypair()
    let group = try GroupKeys.createSealed(to: Sodium.toBase64(member.publicKey))
    let someoneElse = Sodium.toBase64(Sodium.keypair().publicKey)
    XCTAssertThrowsError(try GroupKeys.open(group.sealedPrivateKey, holder: member, expectedPublicKey: someoneElse)) { XCTAssertTrue($0 is KeyMismatchError) }
  }

  func testTheWholeCustodyChainMemberToGroupToWriterToClaimTokenEndsAtALetter() throws {
    let member = Sodium.keypair()
    let group = try GroupKeys.createSealed(to: Sodium.toBase64(member.publicKey))
    let writer = try GroupKeys.createSealed(to: group.publicKey)

    // The group writes for the writer: envelopes to the writer and to itself.
    let letter = try LetterCipher.encrypt(body: "Dear Jane", relayNote: "Please use the blue paper", readers: [
      Reader(type: Reader.user, id: 47, publicKey: writer.publicKey), Reader(type: Reader.chapter, id: 1, publicKey: group.publicKey, keyVersion: 1),
    ])

    // A member reads it both ways: with the group key, and with the writer's key held in custody.
    let groupKey = try GroupKeys.open(group.sealedPrivateKey, holder: member, expectedPublicKey: group.publicKey)
    let writerKey = try GroupKeys.open(writer.sealedPrivateKey, holder: groupKey, expectedPublicKey: writer.publicKey)
    for (envelope, key) in [(letter.envelopes[1], groupKey), (letter.envelopes[0], writerKey)] {
      let contentKey = try LetterCipher.openEnvelope(envelope.wrappedKey, keyPair: key)
      XCTAssertEqual(try LetterCipher.decryptText(ciphertext: letter.body.ciphertext, nonce: letter.body.nonce, contentKey: contentKey), "Dear Jane")
    }

    // Hand-off: the token wraps the same private key, and the server is given only the hash.
    let claim = try GroupKeys.claimToken(writerPrivateKey: writerKey.privateKey)
    XCTAssertTrue(SecretCodes.isWellFormed(claim.token))
    XCTAssertEqual(SecretCodes.hashHex(SecretCodes.pretty(claim.token).lowercased()), claim.tokenHash)
    let claimed = try AccountKeys.unlockWithCode(publicKey: writer.publicKey, wrapped: claim.wrapped.wrapped, code: claim.token.lowercased(), salt: claim.wrapped.salt, params: claim.wrapped.params)
    XCTAssertEqual(writer.keyPair.privateKey, claimed.privateKey)
  }
}
