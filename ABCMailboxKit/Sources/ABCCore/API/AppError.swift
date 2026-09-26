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
  /// A lifecycle or state conflict (409), for example moving a letter backwards. `name` is the API's
  /// error name (`KeyVersionError`, `LetterStatusError`, `IdempotencyError`), for the few callers that
  /// must tell them apart.
  /// `condition`: the API's code for why, where it sends one (API PR #117: `AccountDeleteError` says `group_owner`, `last_key_holder`, …).
  case conflict(String?, name: String? = nil, condition: String? = nil)
  /// A used or expired claim token (410).
  /// `condition` says why, where the server says so: a claim token that is `expired` sends the person to their
  /// group for a new one; one that is `used` means somebody has the account already, which is a different conversation.
  case gone(String?, condition: String? = nil)
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
    case .unauthorized(let info), .notFound(let info), .gone(let info, _): return info
    case .conflict(let info, _, _): return info
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

  public var isForbidden: Bool { if case .forbidden = self { return true } else { return false } }
  public var conflictCondition: String? { if case .conflict(_, _, let condition) = self { return condition } else { return nil } }
  public var isConflict: Bool { if case .conflict = self { return true } else { return false } }
  /// The same Idempotency-Key is being processed right now (a retry racing the original, API PR #97):
  /// wait a second and ask again. Not to be confused with a group's key rotation, which is also a 409.
  public var isStillProcessing: Bool { if case .conflict(_, name: "IdempotencyError", _) = self { return true } else { return false } }
  /// The server would not take the password in the form it was sent: a plain password for a split account, or the
  /// other way round (API PR #114, `409 AuthSchemeError`).
  public var isSchemeRefused: Bool { if case .conflict(_, name: "AuthSchemeError", _) = self { return true } else { return false } }
  /// A group rotated its key between our reading it and our using it.
  public var isKeyRotated: Bool { if case .conflict(_, name: "KeyVersionError", _) = self { return true } else { return false } }
  /// A status move lost a race: another volunteer, or a double tap, got there first, or the letter was held or
  /// handed to another group in that moment. The letter is very probably already where the person wanted it,
  /// so this is "look again", not a failure to show in red.
  public var isChangedMeanwhile: Bool { if case .conflict(let text?, name: "LetterStatusError", _) = self { return text.contains("meanwhile") } else { return false } }
  /// The letter is held (its prisoner was moved or freed) and the request did not say `release` (API PR #106).
  public var isLetterHeld: Bool { if case .conflict(_, name: "LetterHeldError", _) = self { return true } else { return false } }
  /// A pen name change the limits do not allow (API #127): `cooldown` (once every 90 days) or `new_names` (two
  /// brand-new names a year). Nil for anything else.
  public var penNameLimit: String? { if case .conflict(_, name: "PenNameLimitError", let condition) = self { return condition ?? "cooldown" } else { return nil } }
  public var isNotFound: Bool { if case .notFound = self { return true } else { return false } }
  /// Why something is gone. The API keeps a code for it (`expired`, `used`) but does not put it in the answer yet;
  /// what arrives is the sentence it builds from the code, "Claim token is expired." So the code is read back out
  /// of that sentence, and a `condition` field wins the day it is sent. Anything unrecognised is nil: a plain "gone".
  static func goneCondition(_ condition: String?, error: String?) -> String? {
    if let condition = condition?.trimmingCharacters(in: .whitespaces), !condition.isEmpty { return condition }
    guard let error = error?.trimmingCharacters(in: .whitespaces) else { return nil }
    for subject in ["Claim token", "Invitation"] {
      for code in ["expired", "used"] where error == "\(subject) is \(code)." { return code }
    }
    return nil
  }

  public var goneBecause: String? { if case .gone(_, let condition) = self { return condition } else { return nil } }
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
