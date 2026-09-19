import ABCCore
import SwiftUI

/// Said plainly and without alarm: the directory still works, it is just as of a date.
struct SavedCopyBanner: View {
  let at: Date

  var body: some View {
    Text("No connection. Showing the directory saved on this phone on \(Format.long(at)). Letters cannot be sent until you are back online; drafts are kept.")
      .font(Theme.caption)
      .foregroundStyle(Theme.red)
      .padding(.horizontal, 20).padding(.vertical, 10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Theme.redWash)
  }
}

extension View {
  /// The banner belongs to the screens that read the directory; a letter thread that fails offline says so itself.
  func savedCopyBanner(_ app: AppModel) -> some View {
    safeAreaInset(edge: .top, spacing: 0) {
      if case .saved(let at) = app.container.directory.source { SavedCopyBanner(at: at) }
    }
  }
}

/// On the Account tab for everyone, signed in or not: what the phone can show without a
/// connection, and a way to refresh it before going somewhere with no signal.
struct OfflineCopySection: View {
  let app: AppModel
  @State private var updating = false
  @State private var message: String?

  var body: some View {
    let offline = app.container.offline
    VStack(alignment: .leading, spacing: 6) {
      Text("Offline directory").font(Theme.titleMedium)
      if let saved = offline.savedAt {
        Muted("Saved \(Format.long(saved)): \(Format.plural(offline.counts.prisoners, "prisoner")), \(offline.counts.facilities) facilities, \(Format.plural(offline.counts.groups, "group")). Addresses and mail rules can be looked up without a connection; it refreshes by itself about once a day.", font: Theme.caption)
      } else {
        Muted("Nothing is saved on this phone yet. The directory is downloaded by itself when there is a connection.", font: Theme.caption)
      }
      Button(updating ? "Updating…" : "Update now") { Task { await update() } }.buttonStyle(.outline).disabled(updating)
      if let message { Muted(message, font: Theme.caption) }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func update() async {
    guard !updating else { return }
    updating = true; message = nil
    defer { updating = false }
    do {
      try await app.container.offline.download()
      message = "Updated just now."
    } catch {
      message = "Could not update: \(AppError.from(error).userMessage ?? "no connection"). The earlier copy is untouched."
    }
  }
}
