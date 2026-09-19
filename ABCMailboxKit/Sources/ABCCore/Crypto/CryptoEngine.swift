import ABCCrypto
import Foundation

struct NewAccountKeys: Sendable {
  let keyPair: Sodium.KeyPair
  let fields: AccountKeyFields
  let recoveryCode: String
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
