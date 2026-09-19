import ABCCore
import SwiftUI

/// The process-wide entry point. Everything long-lived is built once, in `AppModel`,
/// and handed down through the SwiftUI environment.
@main
struct ABCMailboxApp: App {
  @State private var app = AppModel(container: AppContainer(defaultBaseURL: BuildInfo.apiBaseURL))

  init() { Theme.applyAppearance() }

  var body: some Scene {
    WindowGroup {
      RootView()
        .environment(app)
        .tint(Theme.red)
    }
  }
}

enum BuildInfo {
  static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"

  /// `APIBaseURL` in Info.plist, which the build fills from the `API_BASE_URL` build setting:
  /// `http://localhost:3000/` for Debug (the simulator shares the Mac's network, so the
  /// Mac's localhost is the simulator's too) and the deployed API for Release.
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
