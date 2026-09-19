import ABCCore
import SwiftUI

/// After `inbox-writer.html`: one row per conversation, newest activity first (server order).
struct InboxView: View {
  @Environment(AppModel.self) private var app

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("Inbox").font(Theme.headline).padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 12)
      if let user = app.user {
        if app.sessions.keysLocked {
          UnlockPrompt(app: app)
        } else if user.isStaff {
          // Group members get the queue, the conversations they can see, and their writers.
          GroupInboxView(app: app, user: user)
        } else {
          ConversationsView(app: app, name: user.displayName, canStartLetter: true)
        }
      } else {
        VStack(alignment: .leading, spacing: 12) {
          Text("Sign in to see your conversations and write letters.").font(Theme.bodyLarge)
          Button("Sign in") { app.signIn() }.buttonStyle(.primaryCompact)
        }
        .padding(.horizontal, 20)
      }
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Theme.paper)
    .toolbar(.hidden, for: .navigationBar)
    // A different account means different conversations: build the lists again rather than show the last person's.
    .id(app.user?.id)
  }
}

struct ConversationsView: View {
  let app: AppModel
  let name: String
  /// Writers start letters here; a group starts them from its Writers tab.
  let canStartLetter: Bool
  @State private var loader: PagedLoader<LetterThread>

  init(app: AppModel, name: String, canStartLetter: Bool) {
    self.app = app
    self.name = name
    self.canStartLetter = canStartLetter
    let letters = app.container.letters
    _loader = State(initialValue: PagedLoader { try await letters.threads(page: $0, pageSize: $1) })
  }

  var body: some View {
    PagedList(loader: loader, emptyText: canStartLetter ? "No conversations yet. Start one with the button below." : "No conversations yet. Start one from the Writers tab.") {
      Muted("Signed in as \(name)").padding(.horizontal, 20).padding(.bottom, 4)
    } row: { t in
      ThreadRow(thread: t, showWriter: !canStartLetter) { app.push(.thread(chatId: t.id)) }
    }
    .overlay(alignment: .bottomTrailing) {
      if canStartLetter {
        FloatingButton(title: "New letter", symbol: "square.and.pencil") { app.push(.pickPrisoner(writerId: nil, writerName: nil)) }.padding(20)
      }
    }
    // Coming back from compose or a thread: reload so new letters and status changes show.
    .onAppear { Task { await loader.refresh() } }
  }
}

struct ThreadRow: View {
  let thread: LetterThread
  var showWriter = false
  let action: () -> Void

  var body: some View {
    let t = thread
    let direction: String = {
      guard let last = t.lastMessage else { return "No letters yet" }
      return last.fromPrisoner ? "← Letter received" : "→ Letter sent · \(last.status.label)"
    }()
    let writer = showWriter ? t.writer.map { "Writer: \($0.label)" } : nil
    let facility = t.prisoner?.facility.map { $0.name + ($0.country.map { ", \($0)" } ?? "") }
    let secondary = [writer, facility].compactMap { $0 }.joined(separator: " · ")
    RecordRow(
      title: t.title, secondary: secondary.isEmpty ? nil : secondary,
      subtitle: direction + (t.lastActivity.map { " · \(Format.short($0))" } ?? ""), action: action
    )
  }
}

/// The floating action the Android app uses for "New letter" and "Write": a capsule over the list's corner.
struct FloatingButton: View {
  let title: String
  let symbol: String
  var color: Color = Theme.ink
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Label(title, systemImage: symbol)
        .font(Theme.titleMedium).foregroundStyle(Theme.paper)
        .padding(.horizontal, 18).padding(.vertical, 14)
        .background(color, in: Capsule())
        .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
    }
    .buttonStyle(.plain)
  }
}

/// End-to-end server, signed in, but this device does not hold the private key (restored phone, reinstalled app).
struct UnlockPrompt: View {
  let app: AppModel
  @State private var password = ""
  @State private var show = false
  @State private var busy = false
  @State private var error: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Your letters are locked on this device. Enter your password to unlock them. It is used here, on the phone, to open your encryption key; it is not sent anywhere.").font(Theme.bodyLarge)
      PasswordField(label: "Password", text: $password, show: $show) { Task { await unlock() } }
      ErrorText(error)
      Button(busy ? "Unlocking…" : "Unlock") { Task { await unlock() } }.buttonStyle(.primaryCompact).disabled(busy || password.isEmpty)
    }
    .padding(.horizontal, 20)
    .disabled(busy)
    .onChange(of: password) { error = nil }
  }

  private func unlock() async {
    guard !password.isEmpty, !busy else { return }
    busy = true; error = nil
    defer { busy = false }
    do {
      try await app.sessions.unlock(password: password)
      password = ""
    } catch {
      self.error = AppError.from(error).userMessage ?? "Could not unlock. Check your connection."
    }
  }
}
