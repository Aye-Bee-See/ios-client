import ABCCore

/// The rules a new account's form checks before its button works (joining, accepting an invitation). A disabled
/// button says nothing on its own, so the first thing still missing is shown under it as a sentence.
enum NewAccountForm {
  static let usernameLength = 3...16

  static func usernameTooLong(_ username: String) -> Bool { username.trimmingCharacters(in: .whitespaces).count > usernameLength.upperBound }

  static func missing(username: String, password: String, confirm: String, understood: Bool) -> String? {
    let name = username.trimmingCharacters(in: .whitespaces)
    if name.isEmpty { return "Choose a username." }
    if name.count < usernameLength.lowerBound { return "A username has at least \(usernameLength.lowerBound) characters." }
    if name.count > usernameLength.upperBound { return "Your username is \(name.count) characters; it can have at most \(usernameLength.upperBound)." }
    if !PasswordRules.isLongEnough(password) { return "Your password needs at least \(PasswordRules.minLength) characters." }
    if confirm.isEmpty { return "Type your password again to confirm it." }
    if password != confirm { return "The two passwords do not match." }
    if !understood { return "Tick the box to say you understand that a lost password cannot be reset by email." }
    return nil
  }
}
