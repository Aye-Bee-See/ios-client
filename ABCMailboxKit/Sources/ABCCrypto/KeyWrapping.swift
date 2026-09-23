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

  /// Split scheme: the key that locks the private key is derived elsewhere (`SplitAuth`) from the password *and*
  /// the same salt and recipe the account signs in with, so both are recorded with the wrapped key as before.
  /// The wire format is unchanged; what differs is which key the box was locked with.
  public static func wrapWithKey(privateKey: Data, key: Data, salt: Data, params: KdfParams) throws -> WrappedKey {
    let enc = try Sodium.aeadEncrypt(privateKey, key: key)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
    let json = try encoder.encode(Box(ciphertext: Sodium.toBase64(enc.ciphertext), nonce: Sodium.toBase64(enc.nonce)))
    return WrappedKey(wrapped: String(decoding: json, as: UTF8.self), salt: Sodium.toBase64(salt), params: params)
  }

  /// Throws `WrongSecretError` when the key is wrong (or the data was tampered with).
  public static func unwrapWithKey(_ wrapped: String, key: Data) throws -> Data {
    let box = try JSONDecoder().decode(Box.self, from: Data(wrapped.utf8))
    do {
      return try Sodium.aeadDecrypt(Sodium.fromBase64(box.ciphertext), nonce: Sodium.fromBase64(box.nonce), key: key)
    } catch {
      throw WrongSecretError()
    }
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

/// An account's key fields for the split scheme, with the auth key that goes to the server as the password. The
/// private key is wrapped under the wrap key derived from the same salt and recipe, so one sign-in derivation
/// gives both what the server checks and what opens the key.
public struct SplitAccountKeys: Sendable {
  public let fields: AccountKeyFields
  public let authKey: String
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

  // MARK: The split scheme (API PR #114)

  /// A brand-new keypair for a split account.
  public static func createSplit(password: String, recoveryCode: String) throws -> (Sodium.KeyPair, SplitAccountKeys) {
    let kp = Sodium.keypair()
    return (kp, try wrapExistingSplit(kp, password: password, recoveryCode: recoveryCode))
  }

  /// Same keypair, new password (split) and a new recovery code: claim, recovery, a password change.
  public static func wrapExistingSplit(_ keyPair: Sodium.KeyPair, password: String, recoveryCode: String, params: KdfParams = .standard) throws -> SplitAccountKeys {
    let split = try wrapForSplitPassword(keyPair, password: password, params: params)
    let fields = AccountKeyFields(publicKey: Sodium.toBase64(keyPair.publicKey), password: split.wrapped, recovery: try KeyWrapping.wrap(privateKey: keyPair.privateKey, secret: SecretCodes.normalise(recoveryCode)))
    return SplitAccountKeys(fields: fields, authKey: split.authKey)
  }

  /// The password wrap alone (a password change keeps the recovery code), with the auth key. A fresh salt every time.
  public static func wrapForSplitPassword(_ keyPair: Sodium.KeyPair, password: String, params: KdfParams = .standard) throws -> (wrapped: WrappedKey, authKey: String) {
    let salt = Sodium.randomBytes(Sodium.saltBytes)
    let keys = try SplitAuth.derive(password: password, salt: salt, params: params)
    defer { keys.wipe() }
    return (try KeyWrapping.wrapWithKey(privateKey: keyPair.privateKey, key: keys.wrapKey, salt: salt, params: params), keys.authKeyBase64)
  }

  /// A split account that signed in but has no keys yet (made by an admin, or on a server-mode API that later
  /// switched): the new keypair is wrapped under the wrap key of that sign-in, with the same salt and recipe, so
  /// the one derivation keeps opening both the server's door and the key.
  public static func createUnderWrapKey(_ wrapKey: Data, salt: String, params: KdfParams, recoveryCode: String) throws -> (Sodium.KeyPair, AccountKeyFields) {
    let kp = Sodium.keypair()
    let fields = AccountKeyFields(
      publicKey: Sodium.toBase64(kp.publicKey),
      password: try KeyWrapping.wrapWithKey(privateKey: kp.privateKey, key: wrapKey, salt: try Sodium.fromBase64(salt), params: params),
      recovery: try KeyWrapping.wrap(privateKey: kp.privateKey, secret: SecretCodes.normalise(recoveryCode))
    )
    return (kp, fields)
  }

  /// Sign-in, split scheme: the wrap key was derived alongside the auth key that was just sent.
  public static func unlockWithWrapKey(publicKey: String, wrapped: String, wrapKey: Data) throws -> Sodium.KeyPair {
    Sodium.KeyPair(publicKey: try Sodium.fromBase64(publicKey), privateKey: try KeyWrapping.unwrapWithKey(wrapped, key: wrapKey))
  }

  /// Recovery step two: prove possession of the private key by opening the server's sealed challenge.
  public static func openChallenge(_ sealedChallenge: String, keyPair: Sodium.KeyPair) throws -> String {
    Sodium.toBase64(try Sodium.sealOpen(try Sodium.fromBase64(sealedChallenge), publicKey: keyPair.publicKey, privateKey: keyPair.privateKey))
  }
}
