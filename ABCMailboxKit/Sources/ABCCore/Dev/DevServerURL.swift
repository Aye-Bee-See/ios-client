import Foundation

/// The base URL every request is built on. Separate from `DevServerRepository`
/// so the API client does not depend on something that depends on the API client.
public final class DevServerURL: @unchecked Sendable {
  private let lock = NSLock()
  private var value: URL
  public let defaultURL: URL

  public init(defaultURL: URL) {
    self.defaultURL = defaultURL
    self.value = defaultURL
  }

  public func current() -> URL { lock.withLock { value } }
  func update(_ url: URL) { lock.withLock { value = url } }
}
