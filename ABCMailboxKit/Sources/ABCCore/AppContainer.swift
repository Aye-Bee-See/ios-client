import Foundation

/// The composition root: builds every long-lived object once and hands them to
/// the app. It does by hand what Hilt does on Android; with this few objects a
/// dependency-injection library would be more to learn than it saves.
@MainActor
public final class AppContainer {
  public let sessions: SessionRepository
  public let modes: EncryptionModeRepository
  public let vault: KeyVault
  public let keyring: GroupKeyring
  public let directory: DirectoryRepository
  public let offline: OfflineDirectory
  public let letters: LettersRepository
  public let group: GroupRepository
  public let drafts: DraftsRepository
  public let outbox: OutboxRepository
  public let activity: ActivityRepository
  public let accountDeletion: AccountDeletion
  public let files: LocalFiles
  public let devServer: DevServerRepository

  /// - Parameters:
  ///   - defaultBaseURL: the build's API address (`APIBaseURL` in Info.plist).
  ///   - secrets: the Keychain in the app, memory in tests.
  ///   - configuration: tests pass one with a stub `URLProtocol`.
  public init(
    defaultBaseURL: URL,
    secrets: SecretStore = KeychainSecretStore(),
    defaults: UserDefaults = .standard,
    configuration: URLSessionConfiguration = .ephemeral,
    files: LocalFiles = LocalFiles(),
    draftsDirectory: URL? = nil,
    offlineDirectory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("offline", isDirectory: true),
    outboxDirectory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("outbox", isDirectory: true)
  ) {
    // Keychain items outlive the app: deleting it from the phone leaves them behind, and a
    // reinstall would start out signed in with someone's key. `UserDefaults` does die with
    // the app, so its absence marks a fresh install.
    if !defaults.bool(forKey: "has_launched") {
      secrets.deleteAll()
      defaults.set(true, forKey: "has_launched")
    }

    let holder = DevServerURL(defaultURL: defaultBaseURL)
    DevServerRepository.restore(into: holder, from: defaults)
    let cache = SessionCache()
    let api = APIClient(baseURL: holder, cache: cache, configuration: configuration)
    let engine = CryptoEngine()

    modes = EncryptionModeRepository(api: api)
    vault = KeyVault(store: secrets)
    sessions = SessionRepository(secrets: secrets, api: api, cache: cache, modes: modes, engine: engine, vault: vault)
    keyring = GroupKeyring(modes: modes, sessions: sessions, vault: vault, api: api)
    let codec = LetterCodec(modes: modes, vault: vault, sessions: sessions, api: api, keyring: keyring)
    self.files = files
    offline = OfflineDirectory(api: api, directory: offlineDirectory)
    directory = DirectoryRepository(api: api, offline: offline)
    letters = LettersRepository(api: api, files: files, codec: codec, engine: engine)
    group = GroupRepository(api: api, letters: letters, directory: directory, codec: codec, keyring: keyring, engine: engine, vault: vault, sessions: sessions)
    let cipher = SecretCipher(store: secrets)
    drafts = draftsDirectory.map { DraftsRepository(cipher: cipher, directory: $0) } ?? DraftsRepository(cipher: cipher)
    outbox = OutboxRepository(directory: outboxDirectory, cipher: cipher, files: files, letters: letters, sessions: sessions)
    activity = ActivityRepository(api: api, sessions: sessions, defaults: defaults)
    accountDeletion = AccountDeletion(sessions: sessions, modes: modes, letters: letters, group: group, drafts: drafts, outbox: outbox, activity: activity)
    devServer = DevServerRepository(defaults: defaults, holder: holder, sessions: sessions, modes: modes)
  }
}
