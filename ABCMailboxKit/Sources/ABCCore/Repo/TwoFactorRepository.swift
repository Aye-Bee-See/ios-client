import Foundation

/// Two-factor sign-in on one's own account (API #173, #175): what it is now, setting it up, fresh recovery codes,
/// and switching it off. Signing in with it is `SessionRepository.completeTwoFactor`. The secret and the recovery
/// codes are never stored on the phone: the authenticator app holds the one, and the person writes down the other.
@MainActor
public final class TwoFactorRepository {
  private let api: APIClient
  private let sessions: SessionRepository

  init(api: APIClient, sessions: SessionRepository) {
    self.api = api
    self.sessions = sessions
  }

  public func status() async throws -> TwoFactorStatus {
    let envelope: APIEnvelope<TwoFactorStatusDTO> = try await api.get("auth/two-factor")
    let d = try envelope.required("two-factor status")
    return TwoFactorStatus(
      enabled: d.enabled ?? false, enabledAt: d.enabledAt.instant, recoveryCodesLeft: d.recoveryCodesLeft ?? 0,
      required: d.required ?? false, requiredBecause: d.requiredBecause ?? []
    )
  }

  /// A new secret to put in the authenticator app. Nothing changes until it is confirmed; asking again replaces it.
  public func setup() async throws -> TwoFactorSetup {
    let envelope: APIEnvelope<TwoFactorSetupDTO> = try await api.send("POST", "auth/two-factor/setup", body: [String: String]())
    let d = try envelope.required("two-factor setup")
    guard let secret = d.secret?.nonBlank, let uri = d.otpauthUri?.nonBlank else { throw AppError.unexpected("The two-factor setup answer had no secret.") }
    return TwoFactorSetup(secret: secret, otpauthUri: uri)
  }

  /// The first code from the app switches it on. The answer is the recovery codes, the only time they are shown.
  public func confirm(code: String) async throws -> [String] {
    let envelope: APIEnvelope<TwoFactorCodesDTO> = try await api.send("POST", "auth/two-factor/confirm", body: TwoFactorCodeRequest(code: TwoFactorCode.normalise(code)))
    // On now, and a requirement is met; the screen says so (`SessionRepository.twoFactorSetUp`) once the codes are saved.
    // The codes are the one way back in without the phone, and shown only now: an answer without them is not a success.
    guard let codes = try envelope.required("two-factor confirmation").recoveryCodes, !codes.isEmpty else {
      throw AppError.unexpected("Two-factor sign-in was switched on, but the server's answer had no recovery codes. Make new ones under Account, Two-factor sign-in.")
    }
    return codes
  }

  /// A fresh set of recovery codes; the old ones stop working. Takes a code from the app.
  public func newRecoveryCodes(code: String) async throws -> [String] {
    let envelope: APIEnvelope<TwoFactorCodesDTO> = try await api.send("POST", "auth/two-factor/recovery-codes", body: TwoFactorCodeRequest(code: TwoFactorCode.normalise(code)))
    guard let codes = try envelope.required("recovery codes").recoveryCodes, !codes.isEmpty else {
      throw AppError.unexpected("The server's answer had no recovery codes. Try again.")
    }
    return codes
  }

  /// Switches it off, with a code from the app or a recovery code. Refused (`409 required`) while it is required.
  public func disable(code: String? = nil, recoveryCode: String? = nil) async throws {
    try await api.send("DELETE", "auth/two-factor", body: TwoFactorCodeRequest(code: code.map(TwoFactorCode.normalise), recoveryCode: recoveryCode?.trimmed))
  }
}
