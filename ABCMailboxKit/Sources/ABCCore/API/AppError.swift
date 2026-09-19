import Foundation

/// Everything that can go wrong talking to the API, in the vocabulary the
/// screens need. The brief's rule: a 400 carries `errors` (a list of sentences);
/// every other failure carries `info` (one sentence), and a 403's `info` says
/// exactly why, so it is shown verbatim.
public enum AppError: Error, Equatable, Sendable {
  /// The server rejected the input; each entry is a complete sentence.
  case validation([String])
  /// No token, a bad token, or (on login) wrong credentials.
  case unauthorized(String?)
  /// The caller is known but not allowed; the sentence explains what to do.
  case forbidden(String)
  case notFound(String?)
  /// A lifecycle or state conflict (409), for example moving a letter backwards.
  case conflict(String?)
  /// A used or expired claim token (410).
  case gone(String?)
  /// 429: too many sign-in, claim, or recovery attempts. The seconds come from the `Retry-After` header.
  case rateLimited(String?, retryAfterSeconds: Int?)
  case server(status: Int, info: String?)
  /// Could not reach the server at all.
  case network
  /// Something answered, but not our API: the body is not the JSON the app expects. This is what
  /// captive-portal Wi-Fi looks like (a community centre's "accept the terms" page answers every
  /// request with a 200 and HTML), and for the directory it is as good as offline.
  case unreadable(String)
  case unexpected(String)

  /// The sentence to show a person, when one exists.
  public var userMessage: String? {
    switch self {
    case .validation(let errors): return errors.joined(separator: " ")
    case .unauthorized(let info), .notFound(let info), .conflict(let info), .gone(let info): return info
    case .forbidden(let info): return info
    case .rateLimited(let info, let retryAfter):
      if let info { return info }
      if let retryAfter { return "Too many attempts. Try again in \((retryAfter + 59) / 60) minute(s)." }
      return "Too many attempts. Try again later."
    case .server(_, let info): return info
    case .network, .unreadable, .unexpected: return nil
    }
  }

  /// A sentence for any error, including the ones that carry no server text.
  public var readable: String {
    switch self {
    case .network: return "Can't reach the server. Check your connection and try again."
    case .unreadable: return "The server's answer could not be read. On public Wi-Fi, it may be waiting for you to accept its terms in a browser."
    case .notFound(let info): return info ?? "That record doesn't exist or is not public."
    default: return userMessage ?? "Something went wrong. Please try again."
    }
  }

  public var isConflict: Bool { if case .conflict = self { return true } else { return false } }
  public var isNotFound: Bool { if case .notFound = self { return true } else { return false } }
  public var isGone: Bool { if case .gone = self { return true } else { return false } }
  /// No connection, or a reply that is not our API's at all. Only these fall back to the saved directory.
  public var meansNotReachingOurServer: Bool {
    switch self { case .network, .unreadable: return true; default: return false }
  }
  public var isUnauthorized: Bool { if case .unauthorized = self { return true } else { return false } }

  /// `LetterCodec`, the session flows and the group screens all answer "locked" with this one sentence.
  public static let lettersLocked = AppError.forbidden("Your letters are locked on this device. Unlock them with your password first.")

  /// Whatever was thrown, as an `AppError`. Everything the API client throws already is one.
  public static func from(_ error: Error) -> AppError {
    if let e = error as? AppError { return e }
    if error is URLError { return .network }
    if error is CancellationError { return .network }
    return .unexpected(String(describing: error))
  }
}
