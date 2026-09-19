import Foundation

/// The token as the API client needs it (synchronously, from any thread) and a
/// channel for "that token was refused". Written by `SessionRepository`, read by
/// `APIClient`. It exists so neither of those has to know the other.
public final class SessionCache: @unchecked Sendable {
  private let lock = NSLock()
  private var _token: String?
  private var _onUnauthorized: (@Sendable (String) -> Void)?

  public init() {}

  public var token: String? {
    get { lock.withLock { _token } }
    set { lock.withLock { _token = newValue } }
  }

  /// Called with the token that was refused, so a stale report about an old token can be ignored.
  var onUnauthorized: (@Sendable (String) -> Void)? {
    get { lock.withLock { _onUnauthorized } }
    set { lock.withLock { _onUnauthorized = newValue } }
  }

  func reportUnauthorized(_ refusedToken: String) { onUnauthorized?(refusedToken) }
}
