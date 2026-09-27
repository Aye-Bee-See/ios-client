@testable import ABCCrypto
import XCTest

/// Typed codes (recovery codes and claim tokens) are read the way the API reads them (README, "Typed codes"): upper
/// case, letters and digits only, then O as 0 and I, L as 1. The normalised text is what goes into the key
/// derivation, so a client that folds differently derives a different key from the right code (ios-client #12).
final class SecretCodesTests: XCTestCase {
  private let printed = "0123-4567-89AB-CDEF-GHJK-MNPQ"

  func testLookAlikesAreReadAsTheDigitsTheyAreMistakenFor() {
    XCTAssertEqual(SecretCodes.normalise("O123-4567-89AB-CDEF-GHJK-MNPQ"), "0123456789ABCDEFGHJKMNPQ")
    XCTAssertEqual(SecretCodes.normalise("o1i3 l567"), "01131567", "lower case folds too")
    XCTAssertEqual(SecretCodes.normalise(" 0123.4567-89ab "), "0123456789AB", "dashes, dots and spaces go; case does not matter")
    XCTAssertTrue(SecretCodes.isWellFormed("O123-4567-89AB-CDEF-GHJK-MNPQ"), "the typo is not reported as an invalid code")
    XCTAssertFalse(SecretCodes.isWellFormed("U123-4567-89AB-CDEF-GHJK-MNPQ"), "U is not a look-alike of anything, so it stays wrong")
    XCTAssertEqual(SecretCodes.pretty("O123 4567 89ab cdef ghjk mnpq"), printed)
    XCTAssertEqual(SecretCodes.hashHex("O123-4567-89AB-CDEF-GHJK-MNPQ"), SecretCodes.hashHex(printed), "a claim token is found either way")
  }

  func testGeneratedCodesNeverContainALookAlikeSoFoldingChangesNothingTypedCorrectly() {
    for _ in 0..<200 {
      let code = SecretCodes.generate()
      XCTAssertEqual(SecretCodes.normalise(code), code)
      XCTAssertFalse(code.contains { "ILOU".contains($0) })
    }
  }

  func testAKeyWrappedUnderTheRecoveryCodeOpensWhenItIsTypedWithLookAlikes() throws {
    let keyPair = Sodium.keypair()
    let fields = try AccountKeys.wrapExisting(keyPair, password: "a long enough password", recoveryCode: printed)
    for typed in ["O123-4567-89AB-CDEF-GHJK-MNPQ", "o123 4567 89ab cdef ghjk mnpq", printed] {
      let opened = try AccountKeys.unlockWithCode(publicKey: fields.publicKey, wrapped: fields.recovery.wrapped, code: typed, salt: fields.recovery.salt, params: fields.recovery.params)
      XCTAssertEqual(opened.privateKey, keyPair.privateKey, typed)
    }
    XCTAssertThrowsError(try AccountKeys.unlockWithCode(publicKey: fields.publicKey, wrapped: fields.recovery.wrapped, code: "1123-4567-89AB-CDEF-GHJK-MNPQ", salt: fields.recovery.salt, params: fields.recovery.params), "a different code still opens nothing")
  }
}
