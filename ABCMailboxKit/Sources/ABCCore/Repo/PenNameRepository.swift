import Foundation

/// Pen names: the public "is it free?" check for a form as the person types, the account's names and limits, and
/// the change itself (`PUT /auth/user`). Since API #127 a change is limited: once every `cooldownDays`, and
/// `newPerYear` brand-new names a rolling year. The screen reads the limits first, so nobody types into a field
/// that will be refused.
@MainActor
public final class PenNameRepository {
  private let api: APIClient
  private let sessions: SessionRepository

  init(api: APIClient, sessions: SessionRepository) {
    self.api = api
    self.sessions = sessions
  }

  /// Public and rate limited: the caller checks the shape first (`PenName.problem`) and waits for typing to stop.
  public func check(_ name: String) async throws -> PenNameCheck {
    let n = PenName.normalise(name)
    // A signed-in caller asking about their own old name hears "available", so the token goes with it when there is one.
    let envelope: APIEnvelope<PenNameCheckDTO> = try await api.get("auth/pen-name-available", query: [("name", n)])
    let d = try envelope.required("pen name check")
    return PenNameCheck(name: d.name?.nonBlank ?? n, available: d.available ?? false, reason: d.reason?.nonBlank, twoParts: d.twoParts ?? true)
  }

  public func names() async throws -> PenNames {
    let envelope: APIEnvelope<PenNamesDTO> = try await api.get("auth/pen-name")
    let d = try envelope.required("pen names")
    let rows = (d.names ?? []).map { PenNames.Row(name: $0.name, current: $0.current ?? false, since: $0.since.flatMap(parseInstant)) }
    return PenNames(
      current: d.penName?.nonBlank, names: rows,
      changeAllowedAt: d.changeAllowedAt.flatMap(parseInstant), newNamesLeft: d.newNamesLeft ?? 2,
      newNamesWindowEnds: d.newNamesWindowEnds.flatMap(parseInstant), cooldownDays: d.cooldownDays ?? 90, newPerYear: d.newPerYear ?? 2
    )
  }

  /// Sets the pen name. A refusal over the limits is `409 PenNameLimitError` with `condition` `cooldown` or
  /// `new_names` (`AppError.penNameLimit`); a taken or malformed name is a `400`.
  @discardableResult
  public func set(_ name: String) async throws -> String {
    guard let user = sessions.state.user else { throw AppError.unauthorized("You are signed out.") }
    let n = PenName.normalise(name)
    try await api.send("PUT", "auth/user", body: UpdateUserRequest(id: user.id, penName: n))
    return n
  }
}
