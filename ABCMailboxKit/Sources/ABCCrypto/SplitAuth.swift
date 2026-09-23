import Foundation

/// The split sign-in scheme (API PR #114): the password never reaches the server.
///
/// One slow derivation (Argon2id, with the account's salt and recipe) gives a master key, and two cheap ones
/// give two unrelated keys from it: the **wrap key** locks the private key and never leaves the device; the
/// **auth key** is sent to the server *as the password*. The server hashes and compares it exactly as it always
/// did, and never sees anything that opens a letter. Knowing either key tells nobody the other, nor the password.
///
/// Every client must match this byte for byte (the vector is in `SplitAuthTests`): NFKC-normalised UTF-8 bytes
/// of the password into `crypto_pwhash`, then `crypto_kdf_derive_from_key` with id 1 and context `abcwrap_` for
/// the wrap key, id 2 and `abcauth_` for the auth key. The auth key travels as standard base64 with padding,
/// 44 characters.
public enum SplitAuth {
  public static let wrapId: UInt64 = 1
  public static let authId: UInt64 = 2
  public static let wrapContext = "abcwrap_"
  public static let authContext = "abcauth_"

  /// Both keys. Call `wipe()` the moment they have been used: the auth key is a credential and the wrap key
  /// opens everything. A class, so that wiping wipes the one copy everybody holds.
  public final class Keys: @unchecked Sendable {
    public private(set) var wrapKey: Data
    public private(set) var authKey: Data
    init(wrapKey: Data, authKey: Data) { self.wrapKey = wrapKey; self.authKey = authKey }

    /// What is sent as `password`.
    public var authKeyBase64: String { Sodium.toBase64(authKey) }
    public func wipe() {
      wrapKey.resetBytes(in: 0..<wrapKey.count)
      authKey.resetBytes(in: 0..<authKey.count)
    }
  }

  /// From a typed password. The master key exists only inside this call.
  public static func derive(password: String, salt: Data, params: KdfParams = .standard) throws -> Keys {
    var master = try params.derive(secret: password, salt: salt)
    defer { master.resetBytes(in: 0..<master.count) }
    return try fromMaster(master)
  }

  public static func fromMaster(_ master: Data) throws -> Keys {
    Keys(wrapKey: try Sodium.deriveSubkey(masterKey: master, id: wrapId, context: wrapContext), authKey: try Sodium.deriveSubkey(masterKey: master, id: authId, context: authContext))
  }

  /// The server checks this shape before anything else: 44 characters of standard base64, decoding to 32 bytes.
  public static func looksLikeAuthKey(_ text: String) -> Bool {
    text.count == 44 && (try? Sodium.fromBase64(text))?.count == Sodium.keyBytes
  }
}
