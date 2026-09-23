import Foundation

/// What the app keeps about a signed-in account. Stored in the Keychain; see `SessionStore`.
public struct Session: Codable, Equatable, Sendable {
  public var token: String
  public var expiresAtMillis: Double
  public let user: SessionUser
}

public struct SessionUser: Codable, Equatable, Sendable {
  public let id: Int
  public let username: String
  public let name: String?
  public let email: String?
  public let role: String
  public let chapterId: Int?
  /// The chapter whose invite code made this account (API PR #116), or nil. Read from the server, never sent to it.
  public var sponsoredBy: Int? = nil

  public var displayName: String { name?.nonBlank ?? username }
  public var isStaff: Bool { role == Role.chapter || role == Role.admin }
  /// The group this account acts for, when it is a group member.
  public var staffGroupId: Int? { isStaff ? chapterId : nil }
}

public enum Role {
  public static let user = "user"
  public static let chapter = "chapter"
  public static let admin = "admin"
  public static let banned = "banned"
}

extension LoginData {
  func toSession() -> Session {
    Session(
      token: token.token,
      expiresAtMillis: token.expires,
      user: SessionUser(id: user.id, username: user.username, name: user.name, email: user.email, role: user.role, chapterId: user.chapterId, sponsoredBy: user.sponsoredBy)
    )
  }
}

/// Reading the Keychain is synchronous, so unlike Android there is no "loading" state:
/// the app knows whether it is signed in before the first frame.
public enum SessionState: Equatable, Sendable {
  case signedOut
  case signedIn(Session)

  public var session: Session? { if case .signedIn(let s) = self { return s } else { return nil } }
  public var user: SessionUser? { session?.user }
  public var isSignedIn: Bool { session != nil }
}

/// Persists the `Session` across launches. An unreadable blob reads as signed out.
struct SessionStore {
  let store: SecretStore
  private let name = "session"

  func load() -> Session? { store.read(name).flatMap { try? JSONDecoder().decode(Session.self, from: $0) } }
  func save(_ session: Session) { if let data = try? JSONEncoder().encode(session) { store.write(name, data) } }
  func clear() { store.delete(name) }
}
