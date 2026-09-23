import Clibsodium
import Foundation

public enum SodiumError: Error, Equatable {
  case invalidBase64
  case invalidLength(String)
  case operationFailed(String)
  /// Wrong key, wrong secret, or tampered data. libsodium does not say which.
  case cannotOpen
}

/// The only file that talks to libsodium. Everything else in this package (and the
/// app) goes through these functions, so swapping the binding later touches one
/// place. The names mirror the API's `services/crypto.js`, which is the contract
/// every client must match:
///
/// - keypairs: X25519 (`crypto_box_keypair`)
/// - sealing a key to a public key: `crypto_box_seal`
/// - bodies, notes, files, and wrapped private keys: `crypto_aead_xchacha20poly1305_ietf`
///   with no associated data and a random 24-byte nonce
/// - password, recovery code, and claim token derivation: Argon2id (`crypto_pwhash`)
/// - base64: the standard alphabet with padding
public enum Sodium {

  public static let keyBytes = 32
  public static let nonceBytes = 24
  public static let saltBytes = 16
  public static let kdfContextBytes = 8

  /// Default Argon2id cost: libsodium's "interactive" tier, fast enough for a phone.
  public static let opslimitInteractive: UInt64 = 2
  public static let memlimitInteractive: Int = 67_108_864
  public static let algArgon2id13: Int32 = 2

  private static let ready: Bool = {
    precondition(sodium_init() >= 0, "libsodium failed to initialise")
    precondition(keyBytes == crypto_aead_xchacha20poly1305_ietf_keybytes())
    precondition(nonceBytes == crypto_aead_xchacha20poly1305_ietf_npubbytes())
    precondition(saltBytes == crypto_pwhash_saltbytes())
    precondition(kdfContextBytes == crypto_kdf_contextbytes() && keyBytes == crypto_kdf_keybytes())
    precondition(opslimitInteractive == UInt64(crypto_pwhash_opslimit_interactive()))
    precondition(memlimitInteractive == crypto_pwhash_memlimit_interactive())
    precondition(algArgon2id13 == crypto_pwhash_alg_argon2id13())
    precondition(keyBytes == crypto_box_publickeybytes() && keyBytes == crypto_box_secretkeybytes())
    return true
  }()

  /// Loads the library and checks our constants against it. Safe to call more than once; free after the first.
  public static func initialize() { _ = ready }

  public static func randomBytes(_ count: Int) -> Data {
    initialize()
    var out = [UInt8](repeating: 0, count: count)
    randombytes_buf(&out, count)
    return Data(out)
  }

  public static func toBase64(_ bytes: Data) -> String { bytes.base64EncodedString() }

  public static func fromBase64(_ text: String) throws -> Data {
    guard let data = Data(base64Encoded: text) else { throw SodiumError.invalidBase64 }
    return data
  }

  /// A class, not a struct, so that wiping the private key at sign-out wipes the one copy
  /// everybody holds rather than a copy of it.
  public final class KeyPair: @unchecked Sendable {
    public let publicKey: Data
    public private(set) var privateKey: Data

    public init(publicKey: Data, privateKey: Data) {
      self.publicKey = publicKey
      self.privateKey = privateKey
    }

    /// Best effort: overwrites this object's storage. Copies handed out earlier are beyond reach.
    public func wipe() { privateKey.resetBytes(in: 0..<privateKey.count) }
  }

  public static func keypair() -> KeyPair {
    initialize()
    var pk = [UInt8](repeating: 0, count: keyBytes)
    var sk = [UInt8](repeating: 0, count: keyBytes)
    crypto_box_keypair(&pk, &sk)
    return KeyPair(publicKey: Data(pk), privateKey: Data(sk))
  }

  /// `crypto_scalarmult_base`: the X25519 public key that belongs to a private key.
  public static func publicKey(of privateKey: Data) throws -> Data {
    initialize()
    guard privateKey.count == keyBytes else { throw SodiumError.invalidLength("private key must be \(keyBytes) bytes") }
    var out = [UInt8](repeating: 0, count: keyBytes)
    guard crypto_scalarmult_base(&out, [UInt8](privateKey)) == 0 else { throw SodiumError.operationFailed("crypto_scalarmult_base") }
    return Data(out)
  }

  /// `crypto_box_seal`: anyone with the public key can seal; only the private key opens.
  public static func seal(_ message: Data, to recipientPublicKey: Data) throws -> Data {
    initialize()
    guard recipientPublicKey.count == keyBytes else { throw SodiumError.invalidLength("public key must be \(keyBytes) bytes") }
    let m = [UInt8](message)
    var out = [UInt8](repeating: 0, count: m.count + crypto_box_sealbytes())
    guard crypto_box_seal(&out, m, UInt64(m.count), [UInt8](recipientPublicKey)) == 0 else { throw SodiumError.operationFailed("crypto_box_seal") }
    return Data(out)
  }

  public static func sealOpen(_ sealed: Data, publicKey: Data, privateKey: Data) throws -> Data {
    initialize()
    guard publicKey.count == keyBytes, privateKey.count == keyBytes, sealed.count >= crypto_box_sealbytes() else { throw SodiumError.cannotOpen }
    let c = [UInt8](sealed)
    var out = [UInt8](repeating: 0, count: c.count - crypto_box_sealbytes())
    guard crypto_box_seal_open(&out, c, UInt64(c.count), [UInt8](publicKey), [UInt8](privateKey)) == 0 else { throw SodiumError.cannotOpen }
    return Data(out)
  }

  public struct Encrypted: Sendable {
    public let ciphertext: Data
    public let nonce: Data
  }

  /// XChaCha20-Poly1305 with a fresh random nonce and no associated data, as the server does.
  public static func aeadEncrypt(_ plain: Data, key: Data) throws -> Encrypted {
    initialize()
    guard key.count == keyBytes else { throw SodiumError.invalidLength("content key must be \(keyBytes) bytes") }
    let nonce = randomBytes(nonceBytes)
    let m = [UInt8](plain)
    var out = [UInt8](repeating: 0, count: m.count + crypto_aead_xchacha20poly1305_ietf_abytes())
    var outLength: UInt64 = 0
    let rc = crypto_aead_xchacha20poly1305_ietf_encrypt(&out, &outLength, m, UInt64(m.count), nil, 0, nil, [UInt8](nonce), [UInt8](key))
    guard rc == 0 else { throw SodiumError.operationFailed("crypto_aead_xchacha20poly1305_ietf_encrypt") }
    return Encrypted(ciphertext: Data(out.prefix(Int(outLength))), nonce: nonce)
  }

  /// Throws `SodiumError.cannotOpen` on a wrong key or tampering.
  public static func aeadDecrypt(_ ciphertext: Data, nonce: Data, key: Data) throws -> Data {
    initialize()
    let tag = crypto_aead_xchacha20poly1305_ietf_abytes()
    guard key.count == keyBytes, nonce.count == nonceBytes, ciphertext.count >= tag else { throw SodiumError.cannotOpen }
    let c = [UInt8](ciphertext)
    var out = [UInt8](repeating: 0, count: c.count - tag)
    var outLength: UInt64 = 0
    let rc = crypto_aead_xchacha20poly1305_ietf_decrypt(&out, &outLength, nil, c, UInt64(c.count), nil, 0, [UInt8](nonce), [UInt8](key))
    guard rc == 0 else { throw SodiumError.cannotOpen }
    return Data(out.prefix(Int(outLength)))
  }

  /// `crypto_kdf_derive_from_key`: a subkey from a 32-byte master key, named by a number and an eight-character
  /// context. Deterministic, and cheap: the slow part (Argon2id) has already been paid for the master key. Two
  /// subkeys of one master are unrelated to each other, which is the whole point of the split sign-in scheme.
  public static func deriveSubkey(masterKey: Data, id: UInt64, context: String) throws -> Data {
    initialize()
    guard masterKey.count == keyBytes else { throw SodiumError.invalidLength("master key must be \(keyBytes) bytes") }
    let ctx = context.utf8.map { CChar(bitPattern: $0) }
    guard ctx.count == kdfContextBytes, context.allSatisfy(\.isASCII) else { throw SodiumError.invalidLength("context must be exactly \(kdfContextBytes) ASCII characters") }
    var out = [UInt8](repeating: 0, count: keyBytes)
    guard crypto_kdf_derive_from_key(&out, keyBytes, id, ctx, [UInt8](masterKey)) == 0 else { throw SodiumError.operationFailed("crypto_kdf_derive_from_key") }
    return Data(out)
  }

  /// Argon2id, 32 bytes out. The caller stores `salt` and the three cost values as `kdfParams`.
  ///
  /// Two things every client must do identically, or the same password derives
  /// different keys on web and phone (Android found both the hard way, 17 September 2026):
  ///
  /// 1. Normalise the secret to Unicode NFKC, because one visible password can
  ///    be typed as different code point sequences ("ä" precomposed, or "a"
  ///    plus a combining diaeresis) depending on the keyboard.
  /// 2. Hash its UTF-8 bytes, all of them. Here that is simply `Array(string.utf8)`,
  ///    passed with its real length.
  public static func deriveKey(
    secret: String,
    salt: Data,
    opslimit: UInt64 = opslimitInteractive,
    memlimit: Int = memlimitInteractive,
    algorithm: Int32 = algArgon2id13
  ) throws -> Data {
    initialize()
    guard salt.count == saltBytes else { throw SodiumError.invalidLength("salt must be \(saltBytes) bytes") }
    let password = secret.precomposedStringWithCompatibilityMapping.utf8.map { CChar(bitPattern: $0) }
    var out = [UInt8](repeating: 0, count: keyBytes)
    let rc = crypto_pwhash(&out, UInt64(keyBytes), password, UInt64(password.count), [UInt8](salt), opslimit, memlimit, algorithm)
    guard rc == 0 else { throw SodiumError.operationFailed("crypto_pwhash failed (out of memory?)") }
    return Data(out)
  }
}
