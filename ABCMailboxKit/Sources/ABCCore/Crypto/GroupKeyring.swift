import ABCCrypto
import Foundation
import Observation

/// The group's opened keypair. `publicKey` is base64, as it travels; `version` goes on everything sealed to it.
public final class GroupKey: Sendable {
  public let groupId: Int
  public let version: Int
  let keyPair: Sodium.KeyPair
  let publicKey: String

  init(groupId: Int, keyPair: Sodium.KeyPair, publicKey: String, version: Int) {
    self.groupId = groupId
    self.keyPair = keyPair
    self.publicKey = publicKey
    self.version = version
  }
}

/// Where a group member stands with their group's key. Screens explain each case; none is an error to hide.
public enum GroupKeyState: Sendable {
  /// Server mode, a writer's account, or nothing loaded yet.
  case notNeeded
  /// The member's own key is locked on this device, so nothing sealed to them can be opened.
  case locked
  /// Nobody has made the group's keypair yet. Any member can, once.
  case notSetUp(groupId: Int)
  /// The group has a key, but no holder has handed it to this member.
  case notHeld(groupId: Int)
  case ready(GroupKey)
  case failed(AppError)

  public var isReady: Bool { if case .ready = self { return true } else { return false } }
}

/// What a group member needs in order to read: the group's private key (sealed
/// to the member in their key bundle), and through it the private keys of the
/// writers the group still holds in custody. Loaded once per sign-in, kept in
/// memory only, never written to disk: the member's own key in the `KeyVault`
/// is enough to open all of it again on the next launch. See Android's
/// docs/DECISIONS.md, 17 September 2026; the reasoning holds here unchanged.
@MainActor @Observable
public final class GroupKeyring {
  public private(set) var state: GroupKeyState = .notNeeded

  @ObservationIgnored private let modes: EncryptionModeRepository
  @ObservationIgnored private let sessions: SessionRepository
  @ObservationIgnored private let vault: KeyVault
  @ObservationIgnored private let api: APIClient
  @ObservationIgnored private var loadedFor: Int?
  @ObservationIgnored private var writers: [Int: Sodium.KeyPair] = [:]
  @ObservationIgnored private var inFlight: Task<GroupKeyState, Never>?

  init(modes: EncryptionModeRepository, sessions: SessionRepository, vault: KeyVault, api: APIClient) {
    self.modes = modes
    self.sessions = sessions
    self.vault = vault
    self.api = api
    // Signing out (or a refused token) wipes the keys now, not at the next load.
    sessions.onSignedOut.append { [weak self] in self?.forget() }
  }

  private var member: SessionUser? { sessions.state.user.flatMap { $0.staffGroupId != nil ? $0 : nil } }

  func groupKey() -> GroupKey? {
    guard case .ready(let key) = state, loadedFor == member?.id else { return nil }
    return key
  }

  /// The keypair of a writer in this group's custody, if loaded.
  func writerKey(_ writerId: Int) -> Sodium.KeyPair? { loadedFor == member?.id ? writers[writerId] : nil }

  /// A writer this device just created: usable without a reload.
  func remember(writerId: Int, keyPair: Sodium.KeyPair) { if groupKey() != nil { writers[writerId] = keyPair } }

  func forget() {
    writers.values.forEach { $0.wipe() }
    writers.removeAll()
    if case .ready(let key) = state { key.keyPair.wipe() }
    loadedFor = nil
    state = .notNeeded
  }

  /// Loads if needed. Cheap when already loaded, and a no-op for writers and in server mode.
  /// Calls never overlap: a second caller waits for the first and, unless it insists, takes its answer.
  @discardableResult
  public func load(force: Bool = false) async -> GroupKeyState {
    if let inFlight {
      let answer = await inFlight.value
      if !force { return answer }
    }
    let task = Task { await self.reallyLoad(force: force) }
    inFlight = task
    let answer = await task.value
    if inFlight == task { inFlight = nil }
    return answer
  }

  private func reallyLoad(force: Bool) async -> GroupKeyState {
    guard let me = member, await modes.current() == .e2e else {
      if loadedFor != nil { forget() }
      return .notNeeded
    }
    // Only a loaded key is final; every other state is worth asking about again (someone may have handed the key over).
    if !force, loadedFor == me.id, state.isReady { return state }
    forget()
    guard let mine = vault.keyPair(for: me.id) else { return set(.locked) }

    let org: OrgKeyDTO?
    do {
      let envelope: APIEnvelope<KeyBundleDTO> = try await api.get("auth/keys")
      org = envelope.data?.orgKey
    } catch {
      return set(.failed(.from(error)))
    }
    let groupId = org?.chapterId ?? me.chapterId ?? 0
    guard let publicKey = org?.chapterPublicKey else { return set(.notSetUp(groupId: groupId)) }
    guard let sealed = org?.wrappedOrgPrivateKey,
          // Sealed to a key this member no longer has (they recovered onto a new keypair), or tampered with.
          let groupPair = try? GroupKeys.open(sealed, holder: mine, expectedPublicKey: publicKey)
    else { return set(.notHeld(groupId: groupId)) }

    loadedFor = me.id
    set(.ready(GroupKey(groupId: groupId, keyPair: groupPair, publicKey: publicKey, version: org?.keyVersion ?? 1)))

    // Custody keys. A failure here leaves those writers' own envelopes closed; the group's envelopes still open.
    if let envelope: APIEnvelope<[WriterDTO]> = try? await api.get("auth/writers", query: [("page_size", "100")]) {
      for w in envelope.data ?? [] {
        guard let sealedWriterKey = w.orgWrappedPrivateKey, let opened = try? GroupKeys.open(sealedWriterKey, holder: groupPair, expectedPublicKey: w.publicKey) else { continue }
        writers[w.id] = opened
      }
    }
    return state
  }

  @discardableResult
  private func set(_ new: GroupKeyState) -> GroupKeyState {
    state = new
    return new
  }
}
