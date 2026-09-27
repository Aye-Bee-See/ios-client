import Foundation

/// One failure of a `400` (API #133): the request field it is about, a code, the limits it names, and the API's
/// own English sentence. The value that was sent is never in it.
public struct FieldProblem: Equatable, Sendable {
  /// The path in the request body (`username`, `group.name`); nil when it is about the request as a whole.
  public let field: String?
  public let code: String
  public let min: Int?
  public let max: Int?
  /// `errors[i]` for this problem: shown when the app has no better words for the code.
  public let message: String

  public init(field: String?, code: String, min: Int? = nil, max: Int? = nil, message: String) {
    self.field = field; self.code = code; self.min = min; self.max = max; self.message = message
  }
}

/// A form's view of a refusal: a sentence under each field the form shows, and one line for everything else.
/// The API never translates; the words for the common codes are the app's, and the API's sentence is the fallback,
/// always for `validation_failed`, which means "no finer code yet".
public struct FormErrors: Equatable, Sendable {
  /// Keyed by the API's field path, as the form passes it in.
  public private(set) var byField: [String: String] = [:]
  /// What did not land under a field, or a pointer to the fields that did. Nil when there is nothing to say.
  public private(set) var general: String?

  public init() {}

  /// `fields` maps each API field path this form shows to the label it has on screen.
  public init(_ error: AppError, fields: [String: String]) {
    let problems = error.fieldProblems
    guard !problems.isEmpty else {
      general = error.userMessage ?? error.readable
      return
    }
    var rest: [String] = []
    for p in problems {
      if let field = p.field, let label = fields[field] {
        if byField[field] == nil { byField[field] = Self.sentence(p, label: label) }
      } else {
        rest.append(Self.sentence(p, label: nil))
      }
    }
    general = rest.isEmpty ? "Check the fields marked in red." : rest.joined(separator: " ")
  }

  /// The app's words for a code, or the API's sentence when it has none.
  static func sentence(_ p: FieldProblem, label: String?) -> String {
    let what = label.map { $0.prefix(1).uppercased() + $0.dropFirst() }
    switch (p.code, what) {
    case ("required", let what?): return "\(what) is needed."
    case ("length_out_of_range", let what?):
      if let min = p.min, let max = p.max { return min <= 0 ? "\(what) can be at most \(max) characters." : "\(what) must be \(min) to \(max) characters." }
      return p.message
    case ("not_unique", let what?): return "That \(what.lowercased()) is already taken. Choose another."
    case ("out_of_range", let what?):
      if let min = p.min, let max = p.max { return "\(what) must be from \(min) to \(max)." }
      if let min = p.min { return "\(what) must be \(min) or more." }
      // A maximum alone is not guessed at: the API's sentence says which limit it is.
      return p.message
    case ("not_a_number", let what?): return "\(what) must be a whole number."
    case ("not_an_email", _): return "That does not look like an email address."
    case ("not_a_url", _): return "That does not look like a web address. It should start with https://."
    case ("reserved_value", let what?): return "That \(what.lowercased()) is kept for the site's own use. Choose another."
    // Never the person's to fix: the app sent something the server cannot use.
    case ("not_an_auth_key", _), ("wrong_encryption_mode", _):
      return "This version of the app sent something the server could not use. Update the app, then try again."
    default: return p.message
    }
  }
}
