import Foundation

public struct Draft: Codable, Equatable, Sendable {
  public let body: String
  public let note: String?
  public let relayChapter: Int?
  public let updatedAt: Date

  public init(body: String, note: String?, relayChapter: Int?, updatedAt: Date = Date()) {
    self.body = body
    self.note = note
    self.relayChapter = relayChapter
    self.updatedAt = updatedAt
  }
}

/// An unsent letter, saved as the writer types so nothing is lost to a phone
/// call or a crash. Keyed by account and prisoner: one draft per thread, and a
/// different account on the same phone never sees another's draft.
///
/// Drafts are the one place plaintext must touch disk, so each is a small file
/// sealed with AES-GCM under a key that lives in the Keychain and never leaves
/// the device. A lost phone does not leak an unsent letter, and neither does a backup.
public final class DraftsRepository: Sendable {
  private let directory: URL
  private let cipher: SecretCipher

  public init(cipher: SecretCipher, directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("drafts", isDirectory: true)) {
    self.cipher = cipher
    self.directory = directory
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    var dir = directory
    try? dir.setResourceValues(values)
  }

  private func file(_ userId: Int, _ prisonerId: Int) -> URL { directory.appendingPathComponent("\(userId)_\(prisonerId).draft") }

  public func load(userId: Int, prisonerId: Int) -> Draft? {
    guard let blob = try? Data(contentsOf: file(userId, prisonerId)) else { return nil }
    // An undecryptable draft (phone restored, key gone) is simply lost.
    return try? JSONDecoder().decode(Draft.self, from: cipher.decrypt(blob))
  }

  public func save(userId: Int, prisonerId: Int, draft: Draft) {
    guard let blob = try? cipher.encrypt(JSONEncoder().encode(draft)) else { return }
    try? blob.write(to: file(userId, prisonerId), options: [.atomic, .completeFileProtection])
  }

  public func delete(userId: Int, prisonerId: Int) { try? FileManager.default.removeItem(at: file(userId, prisonerId)) }

  public func deleteAll() {
    for url in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] { try? FileManager.default.removeItem(at: url) }
  }
}
