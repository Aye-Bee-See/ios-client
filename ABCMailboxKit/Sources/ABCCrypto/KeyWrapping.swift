import Foundation

/// A private key wrapped under a human secret (password, recovery code, or
/// claim token): Argon2id turns the secret and a random salt into a 32-byte
/// key, and XChaCha20-Poly1305 encrypts the private key with it.
///
/// Wire format, fixed by the API's reference client: `wrapped` is the JSON
/// string `{"ciphertext": b64, "nonce": b64}`, `salt` is base64 of 16 bytes,
/// and `params` is the agreed `KdfParams` object.
public struct WrappedKey: Equatable, Sendable {
  public let wrapped: String
  public let salt: String
  public let params: KdfParams

  public init(wrapped: String, salt: String, params: KdfParams) {
    self.wrapped = wrapped
    self.salt = salt
    self.params = params
  }
}

/// The secret does not open this key (or the data was tampered with).
public struct WrongSecretError: Error, Equatable {}

public enum KeyWrapping {
  private struct Box: Codable {
    let ciphertext: String
    let nonce: String
  }

  public static func wrap(privateKey: Data, secret: String, params: KdfParams = .standard) throws -> WrappedKey {
    let salt = Sodium.randomBytes(Sodium.saltBytes)
    var key = try params.derive(secret: secret, salt: salt)
    defer { key.resetBytes(in: 0..<key.count) }
    let enc = try Sodium.aeadEncrypt(privateKey, key: key)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
    let json = try encoder.encode(Box(ciphertext: Sodium.toBase64(enc.ciphertext), nonce: Sodium.toBase64(enc.nonce)))
    return WrappedKey(wrapped: String(decoding: json, as: UTF8.self), salt: Sodium.toBase64(salt), params: params)
  }

  /// Throws `WrongSecretError` when the secret is wrong (or the data was tampered with).
  public static func unwrap(_ wrapped: String, secret: String, salt: String, params: KdfParams) throws -> Data {
    let box = try JSONDecoder().decode(Box.self, from: Data(wrapped.utf8))
    var key = try params.derive(secret: secret, salt: Sodium.fromBase64(salt))
    defer { key.resetBytes(in: 0..<key.count) }
    do {
      return try Sodium.aeadDecrypt(Sodium.fromBase64(box.ciphertext), nonce: Sodium.fromBase64(box.nonce), key: key)
    } catch {
      throw WrongSecretError()
    }
  }
}

/// The seven fields the API stores for an account's keys (register, `PUT /auth/keys`, claim).
public struct AccountKeyFields: Sendable {
  public let publicKey: String
  public let password: WrappedKey
  public let recovery: WrappedKey
}

public enum AccountKeys {
  /// A brand-new keypair wrapped under the password and under a recovery code.
  public static func create(password: String, recoveryCode: String) throws -> (Sodium.KeyPair, AccountKeyFields) {
    let kp = Sodium.keypair()
    return (kp, try wrapExisting(kp, password: password, recoveryCode: recoveryCode))
  }

  /// Same keypair, new secrets: used by claim (token to password) and by recovery-code rotation.
  public static func wrapExisting(_ keyPair: Sodium.KeyPair, password: String, recoveryCode: String) throws -> AccountKeyFields {
    AccountKeyFields(
      publicKey: Sodium.toBase64(keyPair.publicKey),
      password: try KeyWrapping.wrap(privateKey: keyPair.privateKey, secret: password),
      recovery: try KeyWrapping.wrap(privateKey: keyPair.privateKey, secret: SecretCodes.normalise(recoveryCode))
    )
  }

  public static func unlockWithPassword(publicKey: String, wrapped: String, password: String, salt: String, params: KdfParams) throws -> Sodium.KeyPair {
    Sodium.KeyPair(publicKey: try Sodium.fromBase64(publicKey), privateKey: try KeyWrapping.unwrap(wrapped, secret: password, salt: salt, params: params))
  }

  /// Claim tokens and recovery codes are typed by people, so they are normalised before derivation.
  public static func unlockWithCode(publicKey: String, wrapped: String, code: String, salt: String, params: KdfParams) throws -> Sodium.KeyPair {
    Sodium.KeyPair(publicKey: try Sodium.fromBase64(publicKey), privateKey: try KeyWrapping.unwrap(wrapped, secret: SecretCodes.normalise(code), salt: salt, params: params))
  }

  /// Recovery step two: prove possession of the private key by opening the server's sealed challenge.
  public static func openChallenge(_ sealedChallenge: String, keyPair: Sodium.KeyPair) throws -> String {
    Sodium.toBase64(try Sodium.sealOpen(try Sodium.fromBase64(sealedChallenge), publicKey: keyPair.publicKey, privateKey: keyPair.privateKey))
  }
}
