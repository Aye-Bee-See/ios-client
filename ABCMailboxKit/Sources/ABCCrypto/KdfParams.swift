import Foundation

/// The `kdfParams` object stored beside every wrapped private key. Agreed
/// between the web and Android clients on 12 September 2026 (API README,
/// "End-to-end mode"); the server only checks that it is an object with a
/// string `kdf`. Every client must be able to read what the others wrote, or
/// an account created on one cannot unlock on another.
///
/// `alg` is libsodium's algorithm id for `crypto_pwhash` (Argon2id 1.3 = 2),
/// recorded so a future library default cannot silently change how an old
/// key is derived. Costs are stored per account so they can be raised for new
/// accounts without invalidating existing ones.
///
/// All four fields are always written, whatever their values.
public struct KdfParams: Codable, Equatable, Sendable {
  public let kdf: String
  public let alg: Int32
  public let opslimit: UInt64
  public let memlimit: Int

  public struct Unsupported: Error, Equatable { public let reason: String }

  public init(
    kdf: String = "argon2id",
    alg: Int32 = Sodium.algArgon2id13,
    opslimit: UInt64 = Sodium.opslimitInteractive,
    memlimit: Int = Sodium.memlimitInteractive
  ) throws {
    guard kdf == "argon2id" else { throw Unsupported(reason: "unsupported kdf: \(kdf)") }
    guard alg == Sodium.algArgon2id13 else { throw Unsupported(reason: "unsupported argon2 variant: \(alg)") }
    guard opslimit >= 1 else { throw Unsupported(reason: "opslimit must be positive") }
    guard memlimit >= 8_192 else { throw Unsupported(reason: "memlimit must be at least 8 KiB") }
    self.kdf = kdf
    self.alg = alg
    self.opslimit = opslimit
    self.memlimit = memlimit
  }

  /// The agreed defaults. They satisfy every check above, so this cannot fail.
  public static let standard = try! KdfParams()

  private enum CodingKeys: String, CodingKey { case kdf, alg, opslimit, memlimit }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      kdf: c.decodeIfPresent(String.self, forKey: .kdf) ?? "argon2id",
      alg: c.decodeIfPresent(Int32.self, forKey: .alg) ?? Sodium.algArgon2id13,
      opslimit: c.decodeIfPresent(UInt64.self, forKey: .opslimit) ?? Sodium.opslimitInteractive,
      memlimit: c.decodeIfPresent(Int.self, forKey: .memlimit) ?? Sodium.memlimitInteractive
    )
  }

  public func derive(secret: String, salt: Data) throws -> Data {
    try Sodium.deriveKey(secret: secret, salt: salt, opslimit: opslimit, memlimit: memlimit, algorithm: alg)
  }
}
