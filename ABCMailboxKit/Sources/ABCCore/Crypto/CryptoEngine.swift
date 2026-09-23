import ABCCrypto
import Foundation

struct NewAccountKeys: Sendable {
  let keyPair: Sodium.KeyPair
  let fields: AccountKeyFields
  let recoveryCode: String
  /// Set for the split scheme: what goes to the server as the password.
  var authKey: String? = nil
}

/// One sign-in's derived keys (API PR #114). `wipe()` zeroes the wrap key as soon as it has opened the private
/// key. The auth key is a `String`, like the typed password it stands in for and the request body it is written
/// into, and Swift gives no way to zero those: it is a credential the server already holds a hash of, worth no
/// more than the password string beside it, and it is not what opens a letter.
final class SplitKeys: @unchecked Sendable {
  private(set) var wrapKey: Data
  let authKey: String
  init(wrapKey: Data, authKey: String) { self.wrapKey = wrapKey; self.authKey = authKey }
  func wipe() { wrapKey.resetBytes(in: 0..<wrapKey.count) }
}

/// The app's doorway to the slow half of `ABCCrypto`. Everything that runs
/// Argon2id is `async` and moves off the main thread, because it is deliberately
/// slow (64 MiB, about half a second on a phone). The fast operations (sealing,
/// XChaCha20) are called on `LetterCipher` and `GroupKeys` directly.
///
/// Android needs an interface here so JVM tests can fake libsodium. libsodium
/// runs fine on a Mac, so the tests in this package use the real thing.
struct CryptoEngine: Sendable {
  private func background<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await Task.detached(priority: .userInitiated, operation: work).value
  }

  func createAccountKeys(password: String) async throws -> NewAccountKeys {
    try await background {
      let code = SecretCodes.generate()
      let (kp, fields) = try AccountKeys.create(password: password, recoveryCode: code)
      return NewAccountKeys(keyPair: kp, fields: fields, recoveryCode: code)
    }
  }

  /// Same keypair, new password and a new recovery code.
  func rewrapAll(_ keyPair: Sodium.KeyPair, password: String) async throws -> NewAccountKeys {
    try await background {
      let code = SecretCodes.generate()
      return NewAccountKeys(keyPair: keyPair, fields: try AccountKeys.wrapExisting(keyPair, password: password, recoveryCode: code), recoveryCode: code)
    }
  }

  func wrapForPassword(_ keyPair: Sodium.KeyPair, password: String) async throws -> WrappedKey {
    try await background { try KeyWrapping.wrap(privateKey: keyPair.privateKey, secret: password) }
  }

  func unlockWithPassword(publicKey: String, wrapped: String, password: String, salt: String, params: JSONValue) async throws -> Sodium.KeyPair {
    try await background { try AccountKeys.unlockWithPassword(publicKey: publicKey, wrapped: wrapped, password: password, salt: salt, params: params.decoded(as: KdfParams.self)) }
  }

  func unlockWithCode(publicKey: String, wrapped: String, code: String, salt: String, params: JSONValue) async throws -> Sodium.KeyPair {
    try await background { try AccountKeys.unlockWithCode(publicKey: publicKey, wrapped: wrapped, code: code, salt: salt, params: params.decoded(as: KdfParams.self)) }
  }

  // MARK: The split scheme (API PR #114): the password never reaches the server. See `SplitAuth` in ABCCrypto.

  /// Sign-in: the account's salt and recipe from `GET /auth/login-params`, the password from the person. Slow.
  func deriveSplit(password: String, salt: String, params: JSONValue) async throws -> SplitKeys {
    try await deriveSplit(password: password, salt: salt, params: try params.decoded(as: KdfParams.self))
  }

  func deriveSplit(password: String, salt: String, params: KdfParams) async throws -> SplitKeys {
    try await background {
      let keys = try SplitAuth.derive(password: password, salt: try Sodium.fromBase64(salt), params: params)
      defer { keys.wipe() }
      return SplitKeys(wrapKey: keys.wrapKey, authKey: keys.authKeyBase64)
    }
  }

  /// A fresh salt, base64, for a split password that is set where there are no keys to wrap.
  func newSalt() -> String { Sodium.toBase64(Sodium.randomBytes(Sodium.saltBytes)) }

  func createAccountKeysSplit(password: String) async throws -> NewAccountKeys {
    try await background {
      let code = SecretCodes.generate()
      let (kp, split) = try AccountKeys.createSplit(password: password, recoveryCode: code)
      return NewAccountKeys(keyPair: kp, fields: split.fields, recoveryCode: code, authKey: split.authKey)
    }
  }

  /// A split account with no keys yet gets them wrapped under the wrap key of the sign-in that just happened, under the same salt.
  func createAccountKeysUnderWrapKey(_ wrapKey: Data, salt: String, params: JSONValue) async throws -> NewAccountKeys {
    try await background {
      let code = SecretCodes.generate()
      let (kp, fields) = try AccountKeys.createUnderWrapKey(wrapKey, salt: salt, params: try params.decoded(as: KdfParams.self), recoveryCode: code)
      return NewAccountKeys(keyPair: kp, fields: fields, recoveryCode: code)
    }
  }

  func rewrapAllSplit(_ keyPair: Sodium.KeyPair, password: String) async throws -> NewAccountKeys {
    try await background {
      let code = SecretCodes.generate()
      let split = try AccountKeys.wrapExistingSplit(keyPair, password: password, recoveryCode: code)
      return NewAccountKeys(keyPair: keyPair, fields: split.fields, recoveryCode: code, authKey: split.authKey)
    }
  }

  /// The password wrap alone, with the auth key: a password change keeps the recovery code.
  func wrapForSplitPassword(_ keyPair: Sodium.KeyPair, password: String) async throws -> (wrapped: WrappedKey, authKey: String) {
    try await background { try AccountKeys.wrapForSplitPassword(keyPair, password: password) }
  }

  func unlockWithWrapKey(publicKey: String, wrapped: String, wrapKey: Data) async throws -> Sodium.KeyPair {
    try await background { try AccountKeys.unlockWithWrapKey(publicKey: publicKey, wrapped: wrapped, wrapKey: wrapKey) }
  }

  func newClaimToken(writerPrivateKey: Data) async throws -> NewClaimToken {
    try await background { try GroupKeys.claimToken(writerPrivateKey: writerPrivateKey) }
  }

  /// Attachments can be 20 MiB; keep that off the main thread too.
  func encryptFile(_ bytes: Data, contentKey: Data) async throws -> (ciphertext: Data, nonce: String) {
    try await background { try LetterCipher.encryptFile(bytes, contentKey: contentKey) }
  }

  func decryptFile(_ ciphertext: Data, nonce: String, contentKey: Data) async throws -> Data {
    try await background { try LetterCipher.decryptFile(ciphertext, nonce: nonce, contentKey: contentKey) }
  }
}
