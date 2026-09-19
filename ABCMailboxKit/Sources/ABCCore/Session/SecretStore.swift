import CryptoKit
import Foundation
import Security

/// Small secrets that must survive a restart: the session, the unwrapped keypair,
/// and the key that encrypts drafts. A protocol so tests can use memory instead.
public protocol SecretStore: AnyObject, Sendable {
  func read(_ name: String) -> Data?
  func write(_ name: String, _ data: Data)
  func delete(_ name: String)
  func deleteAll()
}

/// The iOS Keychain. Items are encrypted by the Secure Enclave-backed keybag and
/// are readable only by this app. `AfterFirstUnlockThisDeviceOnly` means two things:
///
/// - *ThisDeviceOnly*: the items never enter an iCloud or computer backup and never
///   migrate to a new phone. This is the iOS counterpart of Android's
///   `allowBackup="false"`: the session token and key material must not leave the device.
/// - *AfterFirstUnlock*: readable while the phone is locked once it has been unlocked
///   since boot, so a background refresh does not find itself signed out.
public final class KeychainSecretStore: SecretStore {
  private let service: String

  public init(service: String = "me.paxana.abcmailbox") { self.service = service }

  private func query(_ name: String?) -> [String: Any] {
    var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
    if let name { q[kSecAttrAccount as String] = name }
    return q
  }

  public func read(_ name: String) -> Data? {
    var q = query(name)
    q[kSecReturnData as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    var out: CFTypeRef?
    guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
    return out as? Data
  }

  public func write(_ name: String, _ data: Data) {
    let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
    let status = SecItemUpdate(query(name) as CFDictionary, attributes as CFDictionary)
    if status == errSecItemNotFound {
      SecItemAdd(query(name).merging(attributes) { $1 } as CFDictionary, nil)
    }
  }

  public func delete(_ name: String) { SecItemDelete(query(name) as CFDictionary) }
  public func deleteAll() { SecItemDelete(query(nil) as CFDictionary) }
}

public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
  private let lock = NSLock()
  private var items: [String: Data] = [:]

  public init() {}
  public func read(_ name: String) -> Data? { lock.withLock { items[name] } }
  public func write(_ name: String, _ data: Data) { lock.withLock { items[name] = data } }
  public func delete(_ name: String) { lock.withLock { items[name] = nil } }
  public func deleteAll() { lock.withLock { items.removeAll() } }
}

/// Encrypts blobs that are too big or too many for the Keychain (letter drafts):
/// AES-256-GCM under a key that itself lives in the `SecretStore`. If the key is
/// gone (the app was reinstalled, the phone restored) decryption throws, and the
/// caller treats the blob as lost.
public struct SecretCipher: Sendable {
  private let store: SecretStore
  private let keyName: String

  public init(store: SecretStore, keyName: String = "draft_key") {
    self.store = store
    self.keyName = keyName
  }

  private func key() -> SymmetricKey {
    if let data = store.read(keyName), data.count == 32 { return SymmetricKey(data: data) }
    let fresh = SymmetricKey(size: .bits256)
    store.write(keyName, fresh.withUnsafeBytes { Data($0) })
    return fresh
  }

  /// 12-byte nonce, ciphertext, 16-byte tag.
  public func encrypt(_ plain: Data) throws -> Data {
    guard let combined = try AES.GCM.seal(plain, using: key()).combined else { throw AppError.unexpected("AES-GCM produced no output.") }
    return combined
  }

  public func decrypt(_ blob: Data) throws -> Data {
    try AES.GCM.open(AES.GCM.SealedBox(combined: blob), using: key())
  }
}
