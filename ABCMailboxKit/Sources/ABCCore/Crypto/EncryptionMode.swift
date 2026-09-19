import Foundation
import Observation

public enum EncryptionMode: Sendable {
  case unknown, server, e2e
}

/// The server says which letter contract it speaks (`GET /health`, API PR #80),
/// so one build of the app works against both modes: it asks once per launch
/// and again whenever the developer server override changes.
@MainActor @Observable
public final class EncryptionModeRepository {
  public private(set) var mode: EncryptionMode = .unknown
  @ObservationIgnored private let api: APIClient

  init(api: APIClient) { self.api = api }

  /// Asks `/health`. Keeps the last known mode if the server cannot be reached.
  @discardableResult
  public func refresh() async -> EncryptionMode {
    if let health: HealthDTO = try? await api.getPlain("health") {
      switch health.encryptionMode {
      case "e2e": mode = .e2e
      case "server": mode = .server
      default: break
      }
    }
    return mode
  }

  /// The known mode, asking the server first if it is not known yet.
  public func current() async -> EncryptionMode { mode != .unknown ? mode : await refresh() }

  /// `GET /health` as a sentence, for the developer server dialog.
  func describeHealth() async throws -> String {
    let health: HealthDTO = try await api.getPlain("health")
    return "\(health.status ?? "?"), \(health.encryptionMode ?? "mode unknown") mode"
  }
}
