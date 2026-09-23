import Foundation

/// Which usernames this device has signed in to with the split scheme (API PR #114). Once one has, the device
/// refuses to sign in to that name as `plain` whatever the server says: a tampered server cannot then talk a
/// known device into sending the real password. The memory is per device and never cleared by signing out or
/// by deleting an account; deleting the app clears it, as it does everything else.
///
/// Only "split" is remembered, never "plain": a plain memory would stop an account moving to split from another device.
///
/// The memory is per server: the same username on a development server the app has been pointed at is a
/// different account, and one known as split on the built-in server must not refuse it there. Entries for the
/// built-in server are bare names (what earlier versions stored); another server's are prefixed with its address.
@MainActor
public final class SchemeMemory {
  private let defaults: UserDefaults
  private let server: DevServerURL
  private let key = "split_usernames"

  init(defaults: UserDefaults, server: DevServerURL) { self.defaults = defaults; self.server = server }

  // The server compares usernames case-insensitively, so one name is one entry however it was typed.
  private func norm(_ username: String) -> String { username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

  private func entry(_ username: String) -> String {
    let url = server.current()
    guard url != server.defaultURL else { return norm(username) }
    let address = url.absoluteString.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    return address + "|" + norm(username)
  }

  public func isKnownSplit(_ username: String) -> Bool { (defaults.stringArray(forKey: key) ?? []).contains(entry(username)) }

  func rememberSplit(_ username: String) {
    var names = defaults.stringArray(forKey: key) ?? []
    let name = entry(username)
    if !names.contains(name) { names.append(name); defaults.set(names, forKey: key) }
  }
}
