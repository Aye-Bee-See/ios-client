import ABCCore

/// The rules a new account's form checks before its button works (joining, accepting an invitation). A disabled
/// button says nothing on its own, so the first thing still missing is shown under it as a sentence.
enum NewAccountForm {
  static let usernameLength = 3...16

  static func usernameTooLong(_ username: String) -> Bool { username.trimmingCharacters(in: .whitespaces).count > usernameLength.upperBound }

  /// `email` is checked only when given: accepting an invitation needs a real address, while a join lets the
  /// server store a placeholder.
  static func missing(username: String, password: String, confirm: String, email: String? = nil, understood: Bool) -> String? {
    let name = username.trimmingCharacters(in: .whitespaces)
    if name.isEmpty { return "Choose a username." }
    if name.count < usernameLength.lowerBound { return "A username has at least \(usernameLength.lowerBound) characters." }
    if name.count > usernameLength.upperBound { return "Your username is \(name.count) characters; it can have at most \(usernameLength.upperBound)." }
    if !PasswordRules.isLongEnough(password) { return "Your password needs at least \(PasswordRules.minLength) characters." }
    if confirm.isEmpty { return "Type your password again to confirm it." }
    if password != confirm { return "The two passwords do not match." }
    if let email {
      let address = email.trimmingCharacters(in: .whitespaces)
      if address.isEmpty { return "Enter your email address." }
      if !address.contains("@") || !address.contains(".") { return "That email address does not look complete." }
    }
    if !understood { return "Tick the box to say you understand that a lost password cannot be reset by email." }
    return nil
  }
}
