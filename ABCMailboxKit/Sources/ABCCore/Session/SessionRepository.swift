import ABCCrypto
import Foundation
import Observation

/// The one place that signs in and out. Screens observe `state`; nothing else
/// touches the token. Lives as long as the process, because sign-in state must
/// outlive any one screen.
@MainActor @Observable
public final class SessionRepository {
  public private(set) var state: SessionState

  /// A recovery code that was just created and must be shown to the writer exactly once.
  public private(set) var pendingRecoveryCode: String?

  /// Goes up by one each time the server ends the session (revoked, expired, banned), so the UI can say so once.
  public private(set) var expiredCount = 0

  /// True when signed in to an end-to-end server without the private key on this device.
  public var keysLocked: Bool {
    guard let user = state.user else { return false }
    return modes.mode == .e2e && vault.unlockedFor != user.id
  }

  @ObservationIgnored private let store: SessionStore
  @ObservationIgnored private let api: APIClient
  @ObservationIgnored private let cache: SessionCache
  @ObservationIgnored private let modes: EncryptionModeRepository
  @ObservationIgnored private let engine: CryptoEngine
  @ObservationIgnored private let vault: KeyVault
  @ObservationIgnored private let schemes: SchemeMemory
  /// Whoever else holds secrets for the signed-in account (the group keyring) clears them here.
  @ObservationIgnored var onSignedOut: [@MainActor () -> Void] = []
  /// The claim check's key material, kept so claiming does not spend a second rate-limited check.
  @ObservationIgnored private var lastClaim: (token: String, info: ClaimInfoDTO)?

  init(secrets: SecretStore, api: APIClient, cache: SessionCache, modes: EncryptionModeRepository, engine: CryptoEngine, vault: KeyVault, schemes: SchemeMemory) {
    self.store = SessionStore(store: secrets)
    self.api = api
    self.cache = cache
    self.modes = modes
    self.engine = engine
    self.vault = vault
    self.schemes = schemes
    let saved = store.load()
    self.state = saved.map(SessionState.signedIn) ?? .signedOut
    cache.token = saved?.token
    // A refused token means the server ended the session (revocation, ban, or
    // expiry). Forget it locally so the app returns to the signed-out state.
    cache.onUnauthorized = { [weak self] refused in
      Task { @MainActor in self?.tokenRefused(refused) }
    }
  }

  private func tokenRefused(_ refused: String) {
    // An old report must never sign out a newer session.
    guard refused == cache.token else { return }
    forgetLocally()
    expiredCount += 1
  }

  private func adopt(_ session: Session) {
    cache.token = session.token
    store.save(session)
    state = .signedIn(session)
  }

  private func forgetLocally() {
    cache.token = nil
    store.clear()
    vault.clear()
    pendingRecoveryCode = nil
    state = .signedOut
    onSignedOut.forEach { $0() }
  }

  /// The writer confirmed they saved the code; forget it.
  public func recoveryCodeSaved() { pendingRecoveryCode = nil }

  // MARK: - Signing in (API PR #114: the password never reaches the server)

  private static let split = "split"

  /// What goes to the server as the password. For a split account it is the auth key, derived here from the
  /// password and the account's salt; the password itself never leaves the phone. For an account made before
  /// the split scheme it is the password, as it always was. The wrap key comes with it, for the private key.
  private struct Credential {
    let serverPassword: String
    let split: SplitKeys?
    let salt: String?
    let params: JSONValue?
    var isSplit: Bool { split != nil }
    func wipe() { split?.wipe() }
    static func plain(_ password: String) -> Credential { Credential(serverPassword: password, split: nil, salt: nil, params: nil) }
  }

  static func downgradeRefused(_ username: String) -> AppError {
    .forbidden("This phone has signed in to \(username) without sending the password, and the server now asks for the password itself. That is not how this account works, so nothing was sent. Try again later; if it keeps happening, tell your group.")
  }

  static let malformedHandshake = AppError.forbidden("The server's sign-in answer was not one this app understands, so nothing was sent. Try again later; if it keeps happening, the app may need updating.")

  /// Step one: the handshake. Nil from an API from before PR #114, which has no such address: every account on it is plain.
  private func loginParams(_ username: String) async throws -> LoginParamsDTO? {
    do {
      let envelope: APIEnvelope<LoginParamsDTO> = try await api.get("auth/login-params", query: [("username", username)], anonymous: true)
      guard let params = envelope.data else { throw Self.malformedHandshake }
      return params
    } catch let e as AppError where e.isNotFound {
      return nil
    }
  }

  /// The password goes to the server in only two cases: the handshake says `plain` in so many words, or there is
  /// no handshake (an API from before the scheme). A 200 with no data, a `split` without its salt and recipe, or a
  /// scheme this app has never heard of is refused, not read as plain: a malformed or tampered answer must not be
  /// a way to be sent the password for a name this phone does not know yet.
  private func credential(username: String, password: String) async throws -> Credential {
    let params = try await loginParams(username)
    if let params, params.isSplit, let salt = params.kdfSalt, let kdf = params.kdfParams {
      let keys = try await engine.deriveSplit(password: password, salt: salt, params: kdf)
      return Credential(serverPassword: keys.authKey, split: keys, salt: salt, params: kdf)
    }
    // This phone has signed in to this name without sending the password. A server that now asks for the
    // password itself is not the server this account was made on, or has been tampered with. Nothing is sent.
    if schemes.isKnownSplit(username) { throw Self.downgradeRefused(username) }
    guard params == nil || params?.scheme == "plain" else { throw Self.malformedHandshake }
    return .plain(password)
  }

  /// Whether the server knows the split scheme at all. Wherever a password is set, it is set split if so.
  private func splitSupported(_ username: String) async throws -> Bool { try await loginParams(username) != nil }

  /// `POST /auth/login` with the credential the handshake calls for, and the answer with the credential the
  /// server accepted. The API decided (its brief, item 23): every account is moved to split before
  /// REQUIRE_SPLIT_AUTH goes on, and a client never sends the password on its own after a refused auth key.
  /// An account from before signs in only by the person's explicit choice (`olderAccount`), which sends the
  /// password as it is, once, by that choice; and even then never for a name this phone knows as split.
  private func signIn(_ name: String, password: String, olderAccount: Bool = false) async throws -> (LoginData, Credential) {
    let cred: Credential
    if olderAccount {
      if schemes.isKnownSplit(name) { throw Self.downgradeRefused(name) }
      cred = .plain(password)
    } else {
      cred = try await credential(username: name, password: password)
    }
    do {
      let envelope: APIEnvelope<LoginData> = try await api.send("POST", "auth/login", body: LoginRequest(username: name, password: cred.serverPassword))
      return (try envelope.required("login response"), cred)
    } catch {
      cred.wipe()
      throw error
    }
  }

  /// `olderAccount`: the person chose "sign in with the password itself", for an account made before the split
  /// scheme on a server that now calls every name split. Not a feature, an escape hatch: the app never sends
  /// the password on its own.
  @discardableResult
  public func login(username: String, password: String, olderAccount: Bool = false) async throws -> Session {
    let name = username.trimmed
    let (response, cred) = try await signIn(name, password: password, olderAccount: olderAccount)
    defer { cred.wipe() }
    var session = response.toSession()
    session.olderAccount = olderAccount
    // A different account signing in over a live one must not inherit its keys.
    if let current = state.user, current.id != session.user.id { forgetLocally() }
    adopt(session)
    if cred.isSplit { schemes.rememberSplit(name) }
    _ = await modes.current()
    await prepareKeys(session, bundle: response.keys, password: password, cred: cred)
    return session
  }

  /// Right after signing in, in either mode (API PR #95). Keys can only be made at sign-in: the
  /// private key is wrapped under the password (or, split, under a key derived beside the auth key),
  /// and this is the one moment the app holds it. So the move to end-to-end encryption does not
  /// depend on reaching every person: it happens as they sign in.
  ///
  /// An account that has keys gets them unwrapped: split, with the wrap key from this very sign-in;
  /// plain, with the password just typed. An account that has none gets a keypair now: generated
  /// here, wrapped (split: under the wrap key, with the sign-in's own salt, so the one derivation keeps
  /// opening both the server's door and the key) and under a new recovery code, and uploaded whole.
  /// The recovery code is then shown once and cannot be skipped. Admins never have keys. A failure
  /// leaves the account signed in; on an end-to-end server it is locked, and the inbox offers to unlock.
  private func prepareKeys(_ session: Session, bundle: KeyBundleDTO?, password: String, cred: Credential) async {
    let userId = session.user.id
    guard session.user.role != Role.admin else { return }
    do {
      // An end-to-end server sends the bundle with the sign-in answer; a server-mode one is asked.
      var bundle = bundle
      if bundle == nil { bundle = (try await api.get("auth/keys") as APIEnvelope<KeyBundleDTO>).data }
      if let m = bundle?.material {
        vault.put(userId: userId, keyPair: try await open(m, password: password, cred: cred))
      } else {
        let fresh: NewAccountKeys
        if let split = cred.split, let salt = cred.salt, let params = cred.params {
          fresh = try await engine.createAccountKeysUnderWrapKey(split.wrapKey, salt: salt, params: params)
        } else {
          fresh = try await engine.createAccountKeys(password: password)
        }
        try await api.send("PUT", "auth/keys", body: KeyFieldsRequest(fresh.fields))
        vault.put(userId: userId, keyPair: fresh.keyPair)
        pendingRecoveryCode = fresh.recoveryCode
      }
    } catch {
      // Signed in but locked; see above.
    }
  }

  /// Opens the account's private key with the sign-in's credential: split, the wrap key; plain, the password.
  private func open(_ m: (publicKey: String, wrapped: String, salt: String, params: JSONValue), password: String, cred: Credential) async throws -> Sodium.KeyPair {
    if let split = cred.split { return try await engine.unlockWithWrapKey(publicKey: m.publicKey, wrapped: m.wrapped, wrapKey: split.wrapKey) }
    return try await engine.unlockWithPassword(publicKey: m.publicKey, wrapped: m.wrapped, password: password, salt: m.salt, params: m.params)
  }

  /// Tells the server to end the token (so a stolen copy stops working), then
  /// forgets it. If the server cannot be reached the local state is cleared
  /// anyway: from the user's point of view they are signed out either way, and
  /// the error says the server was not told.
  public func logout(everywhere: Bool = false) async throws {
    defer { forgetLocally() }
    try await api.send("POST", "auth/logout", body: LogoutRequest(everywhere: everywhere))
  }

  /// Who a claim token is for; the token must already be normalised.
  public func claimInfo(token: String) async throws -> ClaimInfo {
    let envelope: APIEnvelope<ClaimInfoDTO> = try await api.get("auth/claim", query: [("token", token)])
    let d = try envelope.required("claim response")
    lastClaim = (token, d)
    return ClaimInfo(writerName: d.writer.name ?? "your account", groupName: d.chapter?.name, expiresAt: d.expiresAt.flatMap(parseInstant), endToEnd: d.material != nil)
  }

  /// Claims the account, then signs in with the new credentials. Every new account is split where the
  /// server knows the scheme (API PR #114): the password never reaches it.
  @discardableResult
  public func claim(token: String, username: String, password: String, email: String?) async throws -> Session {
    let name = username.trimmed
    let split = try await splitSupported(name)
    var request = ClaimRequest(token: token, username: name, password: password, email: email?.trimmed.nonBlank)
    var recoveryCode: String?
    if let lastClaim, lastClaim.token == token, let m = lastClaim.info.material {
      // End-to-end: the group made this keypair. Open it with the token, then re-wrap the very same
      // key under the new password and a new recovery code. Earlier letters stay readable because
      // the keypair does not change; the group's copy is deleted by the server on claim.
      let fresh: NewAccountKeys
      do {
        let keyPair = try await engine.unlockWithCode(publicKey: m.publicKey, wrapped: m.wrapped, code: token, salt: m.salt, params: m.params)
        fresh = split ? try await engine.rewrapAllSplit(keyPair, password: password) : try await engine.rewrapAll(keyPair, password: password)
      } catch {
        throw AppError.validation(["This token does not open the account's key. Ask your group for a new token."])
      }
      recoveryCode = fresh.recoveryCode
      let f = fresh.fields
      request.wrappedPrivateKey = f.password.wrapped; request.kdfSalt = f.password.salt; request.kdfParams = f.password.params
      request.recoveryWrappedPrivateKey = f.recovery.wrapped; request.recoverySalt = f.recovery.salt; request.recoveryKdfParams = f.recovery.params
      if let authKey = fresh.authKey { request.password = authKey; request.authScheme = Self.split }
    } else if split {
      // No keys to wrap (a server-mode API), but the password still never leaves the phone: an auth key under a fresh salt.
      let salt = engine.newSalt()
      let keys = try await engine.deriveSplit(password: password, salt: salt, params: KdfParams.standard)
      request.password = keys.authKey; request.authScheme = Self.split; request.kdfSalt = salt; request.kdfParams = .standard
      keys.wipe()
    }
    try await api.send("POST", "auth/claim", body: request)
    let session = try await login(username: name, password: password)
    if let recoveryCode { pendingRecoveryCode = recoveryCode }
    return session
  }

  /// Verifies `current` by signing in with it, changes the password, and adopts the fresh token. The new
  /// password goes split wherever the server knows the scheme: this is how an account made before it moves.
  public func changePassword(current: String, new: String) async throws {
    guard let session = state.session else { throw AppError.unauthorized("You are signed out.") }
    // The API does not ask for the current password, so confirm it by signing in with it (in whichever scheme the account uses).
    guard let proof = try await prove(current) else { throw AppError.validation(["Your current password is incorrect."]) }
    defer { proof.wipe() }
    let name = session.user.username
    let split = try await splitSupported(name)
    var request = UpdateUserRequest(id: session.user.id, password: new)
    // The private key is wrapped under the password (or, split, under a key derived beside the auth key), so a
    // new password means a new wrapping: in either mode, now that accounts have keys before the switch.
    // Changing the password without it would leave the key under the old one. If this phone does not hold
    // the key, the current password (just proven right) opens the server's copy.
    // Fetched, not guessed: a failed fetch, or a key on the server that the proven-right password does not open,
    // stops the change, because changing the password without re-wrapping would leave the key under the old
    // one for good. Only a bundle that really has no material takes the no-key path.
    var keyPair = vault.keyPair(for: session.user.id)
    if keyPair == nil {
      let bundle: APIEnvelope<KeyBundleDTO> = try await api.get("auth/keys")
      if let m = bundle.data?.material {
        do { keyPair = try await open(m, password: current, cred: proof) } catch {
          throw AppError.validation(["Your account's key could not be opened with the current password, so the password was not changed. Sign out and in again, then try once more."])
        }
        if let keyPair { vault.put(userId: session.user.id, keyPair: keyPair) }
      }
    }
    if let keyPair {
      if split {
        let (w, authKey) = try await wrappedSplit(keyPair, under: new)
        request.password = authKey; request.authScheme = Self.split
        request.wrappedPrivateKey = w.wrapped; request.kdfSalt = w.salt; request.kdfParams = w.params
      } else {
        let w = try await wrapped(keyPair, under: new)
        request.wrappedPrivateKey = w.wrapped; request.kdfSalt = w.salt; request.kdfParams = w.params
      }
    } else if await modes.current() == .e2e {
      throw AppError.lettersLocked
    } else if split {
      let salt = engine.newSalt()
      let keys = try await engine.deriveSplit(password: new, salt: salt, params: KdfParams.standard)
      request.password = keys.authKey; request.authScheme = Self.split; request.kdfSalt = salt; request.kdfParams = .standard
      keys.wipe()
    }
    let envelope: APIEnvelope<UpdateUserData> = try await api.send("PUT", "auth/user", body: request)
    if split { schemes.rememberSplit(name) }
    // Every older token (including the one just used) is dead now; keep this device signed in. Moved to split,
    // the account is no longer one from before: the next proof of the password goes through the handshake.
    var kept = session
    if split { kept.olderAccount = false }
    if let fresh = envelope.data?.token {
      kept.token = fresh.token
      kept.expiresAtMillis = fresh.expires
    }
    if kept != session { adopt(kept) }
  }

  /// Fetches the key bundle and unwraps it with the password: split, through the wrap key derived beside the auth key.
  public func unlock(password: String) async throws {
    guard let session = state.session else { throw AppError.unauthorized("You are signed out.") }
    let envelope: APIEnvelope<KeyBundleDTO> = try await api.get("auth/keys")
    guard let m = envelope.data?.material else { throw AppError.validation(["This account has no keys yet. Sign out and sign in again to set them up."]) }
    // The session's own way decides: an account signed in as one from before has its key wrapped under the password itself.
    let cred: Credential = session.olderAccount ? .plain(password) : try await credential(username: session.user.username, password: password)
    defer { cred.wipe() }
    do {
      vault.put(userId: session.user.id, keyPair: try await open(m, password: password, cred: cred))
    } catch {
      throw AppError.validation(["That password does not open your letters."])
    }
  }

  /// Recovery with the saved code: proves possession of the key, sets a new password (split, where the server
  /// knows the scheme), signs in.
  @discardableResult
  public func recover(username: String, recoveryCode: String, newPassword: String) async throws -> Session {
    let name = username.trimmed
    let envelope: APIEnvelope<RecoverStartDTO> = try await api.get("auth/recover", query: [("username", name)])
    let start = try envelope.required("recovery response")
    let keyPair: Sodium.KeyPair
    do {
      keyPair = try await engine.unlockWithCode(publicKey: start.publicKey, wrapped: start.recoveryWrappedPrivateKey, code: recoveryCode, salt: start.recoverySalt, params: start.recoveryKdfParams)
    } catch {
      throw AppError.validation(["That recovery code does not match this account. Check it against the copy you saved."])
    }
    // Opening the sealed challenge proves to the server that we hold the private key.
    let challenge: String
    do { challenge = try AccountKeys.openChallenge(start.sealedChallenge, keyPair: keyPair) } catch { throw AppError.unexpected("The server's challenge could not be opened.") }
    let finish: RecoverFinishRequest
    if try await splitSupported(name) {
      let (w, authKey) = try await wrappedSplit(keyPair, under: newPassword)
      finish = RecoverFinishRequest(username: name, challenge: challenge, password: authKey, wrappedPrivateKey: w.wrapped, kdfSalt: w.salt, kdfParams: w.params, authScheme: Self.split)
    } else {
      let w = try await wrapped(keyPair, under: newPassword)
      finish = RecoverFinishRequest(username: name, challenge: challenge, password: newPassword, wrappedPrivateKey: w.wrapped, kdfSalt: w.salt, kdfParams: w.params)
    }
    try await api.send("POST", "auth/recover", body: finish)
    return try await login(username: name, password: newPassword)
  }

  /// Whether `password` is the signed-in account's, asked of the server by signing in with it (in whichever
  /// scheme the account uses). Sign-in never carries the session token, so a wrong guess is not mistaken for a
  /// revoked session, and guesses are rate limited there like any failed sign-in (a 429 is thrown, not swallowed).
  func passwordIsRight(_ password: String) async throws -> Bool {
    guard let proof = try await prove(password) else { return false }
    proof.wipe()
    return true
  }

  /// The credential the server accepted for `password`, or nil when it refused it. The caller wipes it. The
  /// session's own way decides: an account signed in as one from before proves itself with the password.
  private func prove(_ password: String) async throws -> Credential? {
    guard let session = state.session else { throw AppError.unauthorized("You are signed out.") }
    do {
      return try await signIn(session.user.username, password: password, olderAccount: session.olderAccount).1
    } catch let e as AppError where e.isUnauthorized {
      return nil
    }
  }

  /// Deletes the signed-in account and everything the person wrote or received through it (API PR #104).
  /// It cannot be undone. The server wants the current password (split: the auth key); a wrong one is a 403
  /// and deletes nothing. The phone proves the password first, by signing in with it, and sends nothing if
  /// that fails: found on 20 September 2026, when a development server from before PR #104 ignored the field
  /// and deleted an account given a wrong password. A deployed API can lag an app release the same way.
  /// On success every token of the account is dead, so this phone forgets the session and the keys at once.
  /// Use `AccountDeletion`, which also clears what else this phone holds for the account.
  func deleteAccount(password: String) async throws -> DeletedUserDTO {
    guard let user = state.user else { throw AppError.unauthorized("You are signed out.") }
    guard let proof = try await prove(password) else { throw AppError.forbidden("That is not this account's password. Nothing was deleted.") }
    proof.wipe() // only what the server checks is needed here
    let envelope: APIEnvelope<DeletedUserDTO> = try await api.send("DELETE", "auth/user", body: DeleteUserRequest(id: user.id, password: proof.serverPassword))
    forgetLocally()
    return envelope.data ?? DeletedUserDTO(letters: nil, replies: nil, attachments: nil, threads: nil)
  }

  private func wrapped(_ keyPair: Sodium.KeyPair, under password: String) async throws -> WrappedKey {
    do { return try await engine.wrapForPassword(keyPair, password: password) } catch { throw AppError.unexpected("The key could not be wrapped: \(error)") }
  }

  private func wrappedSplit(_ keyPair: Sodium.KeyPair, under password: String) async throws -> (wrapped: WrappedKey, authKey: String) {
    do { return try await engine.wrapForSplitPassword(keyPair, password: password) } catch { throw AppError.unexpected("The key could not be wrapped: \(error)") }
  }
}

extension String {
  var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
