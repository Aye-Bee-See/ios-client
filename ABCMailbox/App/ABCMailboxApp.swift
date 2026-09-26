import ABCCore
import BackgroundTasks
import SwiftUI

/// The process-wide entry point. Everything long-lived is built once, in `AppModel`,
/// and handed down through the SwiftUI environment.
@main
struct ABCMailboxApp: App {
  @State private var app: AppModel
  @Environment(\.scenePhase) private var scenePhase

  init() {
    Theme.applyAppearance()
    let model = AppModel(container: AppContainer(defaultBaseURL: BuildInfo.apiBaseURL))
    _app = State(initialValue: model)

    // Letters written offline. While the app runs, it watches for the network itself; when it does not,
    // iOS may wake it for this task (it must be registered before launch finishes).
    model.container.outbox.onBackgroundFlush = { outcome in
      model.report(outcome)
    }
    model.container.outbox.startWatchingNetwork()
    BGTaskScheduler.shared.register(forTaskWithIdentifier: OutboxNotifier.backgroundTask, using: nil) { task in
      let work = Task { @MainActor in
        let outcome = await model.container.outbox.flush()
        await model.notifier.notify(outcome)
        if outcome.stillWaiting > 0 { OutboxNotifier.scheduleBackgroundSend() }
        task.setTaskCompleted(success: outcome.stillWaiting == 0)
      }
      task.expirationHandler = { work.cancel() }
    }
    // The notification feed, a few times a day when iOS allows. Announced as a notification: nobody is looking.
    BGTaskScheduler.shared.register(forTaskWithIdentifier: ActivityAnnouncer.backgroundTask, using: nil) { task in
      ActivityAnnouncer.scheduleBackgroundRefresh()
      let work = Task { @MainActor in
        await model.container.activity.sync(announce: true)
        task.setTaskCompleted(success: true)
      }
      task.expirationHandler = { work.cancel() }
    }
  }

  var body: some Scene {
    WindowGroup {
      RootView()
        .environment(app)
        .tint(Theme.red)
    }
    .onChange(of: scenePhase) {
      switch scenePhase {
      case .active:
        Task { await app.flushOutbox() }
        Task { await app.syncActivity() }
      case .background:
        if app.container.outbox.hasWaiting { OutboxNotifier.scheduleBackgroundSend() }
        if app.user != nil { ActivityAnnouncer.scheduleBackgroundRefresh() }
      default: break
      }
    }
  }
}

enum BuildInfo {
  static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"

  /// `APIBaseURL` in Info.plist, which the build fills from the `API_BASE_URL` build setting:
  /// `http://localhost:3000/` for Debug (the simulator shares the Mac's network, so the
  /// Mac's localhost is the simulator's too) and, for Release, the public test API at
  /// `https://abctest.letters.support/`, the only deployed one so far.
  static let apiBaseURL: URL = {
    let configured = (Bundle.main.object(forInfoDictionaryKey: "APIBaseURL") as? String).flatMap(URL.init(string:))
    return configured ?? URL(string: "http://localhost:3000/")!
  }()

  static var isDebug: Bool {
    #if DEBUG
    true
    #else
    false
    #endif
  }
}
