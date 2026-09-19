import Foundation

/// A private key sealed to someone else's public key, as the API stores it (base64).
public struct SealedKeyPair: Sendable {
  public let keyPair: Sodium.KeyPair
  public let publicKey: String
  public let sealedPrivateKey: String
}

/// Everything the API needs for a claim token made on the device. The token itself never leaves it.
public struct NewClaimToken: Sendable {
  public let token: String
  public let tokenHash: String
  public let wrapped: WrappedKey
}

/// The opened private key does not belong to the published public key.
public struct KeyMismatchError: Error, Equatable {}

/// The group's side of end-to-end encryption. A group has one keypair; each
/// member holds the group's private key sealed to their own public key, so
/// members come and go without a shared password. A writer the group manages
/// has a keypair the group made, with the private key sealed to the group
/// (custody) until the writer claims the account with a token.
///
/// All of it is `crypto_box_seal` over a raw 32-byte private key, base64.
public enum GroupKeys {

  /// A new keypair with its private key sealed to `holderPublicKey`: a new group for its first member, or a new writer for the group.
  public static func createSealed(to holderPublicKey: String) throws -> SealedKeyPair {
    let kp = Sodium.keypair()
    return SealedKeyPair(keyPair: kp, publicKey: Sodium.toBase64(kp.publicKey), sealedPrivateKey: try sealPrivateKey(kp.privateKey, to: holderPublicKey))
  }

  /// Hand an opened private key to one more holder (a new member).
  public static func sealPrivateKey(_ privateKey: Data, to holderPublicKey: String) throws -> String {
    Sodium.toBase64(try Sodium.seal(privateKey, to: try Sodium.fromBase64(holderPublicKey)))
  }

  /// Open a private key sealed to `holder`. The public key is recomputed from
  /// what came out and compared with `expectedPublicKey`, the one the server
  /// publishes, so a swapped or stale blob is refused rather than used.
  public static func open(_ sealedPrivateKey: String, holder: Sodium.KeyPair, expectedPublicKey: String?) throws -> Sodium.KeyPair {
    let privateKey: Data
    do {
      privateKey = try Sodium.sealOpen(try Sodium.fromBase64(sealedPrivateKey), publicKey: holder.publicKey, privateKey: holder.privateKey)
    } catch {
      throw CannotOpenError(message: "This key was not sealed to the key trying to open it.")
    }
    let publicKey = try Sodium.publicKey(of: privateKey)
    if let expectedPublicKey, publicKey != (try Sodium.fromBase64(expectedPublicKey)) { throw KeyMismatchError() }
    return Sodium.KeyPair(publicKey: publicKey, privateKey: privateKey)
  }

  /// A fresh claim token with the writer's private key wrapped under it (Argon2id, so this is slow on purpose).
  public static func claimToken(writerPrivateKey: Data) throws -> NewClaimToken {
    let token = SecretCodes.generate()
    return NewClaimToken(token: token, tokenHash: SecretCodes.hashHex(token), wrapped: try KeyWrapping.wrap(privateKey: writerPrivateKey, secret: SecretCodes.normalise(token)))
  }
}
