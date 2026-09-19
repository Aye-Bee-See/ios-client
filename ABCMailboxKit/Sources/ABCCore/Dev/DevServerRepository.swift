import Foundation
import Observation

/// A developer override for the API address, so a phone on the same Wi-Fi can
/// talk to the API on a development machine. Stored in `UserDefaults`; nothing
/// stored means the build's default. Only the debug Account screen exposes it.
@MainActor @Observable
public final class DevServerRepository {
  public private(set) var baseURL: String
  public var defaultURL: String { holder.defaultURL.absoluteString }
  public var isOverridden: Bool { baseURL != defaultURL }

  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private let holder: DevServerURL
  @ObservationIgnored private let sessions: SessionRepository
  @ObservationIgnored private let modes: EncryptionModeRepository
  private let key = "dev_api_base_url"

  public struct InvalidURL: Error {
    public let message = "That is not a valid URL. Try http://192.168.1.20:3000/"
  }

  init(defaults: UserDefaults, holder: DevServerURL, sessions: SessionRepository, modes: EncryptionModeRepository) {
    self.defaults = defaults
    self.holder = holder
    self.sessions = sessions
    self.modes = modes
    self.baseURL = holder.current().absoluteString
  }

  /// Reads the stored override into the holder. Called before the first request goes out.
  static func restore(into holder: DevServerURL, from defaults: UserDefaults) {
    if let stored = defaults.string(forKey: "dev_api_base_url"), let url = URL(string: stored), url.host != nil { holder.update(url) }
  }

  /// Normalises the input, saves it, and signs out (a token is only good for the server that issued it).
  @discardableResult
  public func set(_ input: String) async throws -> String {
    guard let normalised = Self.normalise(input), let url = URL(string: normalised) else { throw InvalidURL() }
    defaults.set(normalised, forKey: key)
    await apply(url)
    return normalised
  }

  public func reset() async {
    defaults.removeObject(forKey: key)
    await apply(holder.defaultURL)
  }

  private func apply(_ url: URL) async {
    // Tell the old server first, while the token still means something to it.
    try? await sessions.logout()
    holder.update(url)
    baseURL = url.absoluteString
    await modes.refresh()
  }

  /// `GET /health` at whatever URL is in force.
  public func check() async throws -> String { try await modes.describeHealth() }

  /// Accepts "192.168.1.20", "192.168.1.20:3000", "http://host:3000" and returns "http://host:3000/".
  public nonisolated static func normalise(_ input: String) -> String? {
    var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !s.isEmpty, !s.contains(" ") else { return nil }
    let schemeGiven = s.lowercased().hasPrefix("http://") || s.lowercased().hasPrefix("https://")
    if !schemeGiven { s = "http://" + s }
    guard var c = URLComponents(string: s), let host = c.host, !host.isEmpty else { return nil }
    // A bare host ("192.168.1.20") means the dev API on its default port; an explicit
    // scheme is taken literally, so https://api.example.net stays on 443.
    if !schemeGiven, c.port == nil { c.port = 3000 }
    c.path = "/"
    c.query = nil
    c.fragment = nil
    c.user = nil
    c.password = nil
    return c.string
  }
}
