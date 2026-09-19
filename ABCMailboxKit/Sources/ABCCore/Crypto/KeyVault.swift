import ABCCrypto
import Foundation
import Observation

/// The account's unwrapped keypair, for whoever is signed in. Kept in memory and,
/// so the writer is not asked for their password on every launch, in the Keychain
/// (the brief allows hardware-backed storage, never plain disk). Signing out clears both.
@MainActor @Observable
public final class KeyVault {
  /// The user id whose key is loaded, or nil when locked.
  public private(set) var unlockedFor: Int?
  @ObservationIgnored private var current: (userId: Int, keyPair: Sodium.KeyPair)?
  @ObservationIgnored private let store: SecretStore
  private let name = "key_vault"

  private struct Stored: Codable {
    let userId: Int
    let publicKey: Data
    let privateKey: Data
  }

  init(store: SecretStore) {
    self.store = store
    if let data = store.read(name), let s = try? JSONDecoder().decode(Stored.self, from: data) {
      current = (s.userId, Sodium.KeyPair(publicKey: s.publicKey, privateKey: s.privateKey))
      unlockedFor = s.userId
    }
  }

  func keyPair(for userId: Int) -> Sodium.KeyPair? { current?.userId == userId ? current?.keyPair : nil }

  func put(userId: Int, keyPair: Sodium.KeyPair) {
    current = (userId, keyPair)
    unlockedFor = userId
    if let data = try? JSONEncoder().encode(Stored(userId: userId, publicKey: keyPair.publicKey, privateKey: keyPair.privateKey)) { store.write(name, data) }
  }

  func clear() {
    current?.keyPair.wipe()
    current = nil
    unlockedFor = nil
    store.delete(name)
  }
}
