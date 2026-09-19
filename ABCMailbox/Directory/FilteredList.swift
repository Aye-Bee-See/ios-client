import ABCCore
import Observation
import SwiftUI

/// The three directory lists share one shape: a filter the screen edits, and a
/// paged list that restarts whenever the filter changes, once typing has paused.
@MainActor @Observable
final class FilteredList<Filter: Equatable & Sendable, Item: Identifiable & Sendable> {
  var filter: Filter { didSet { if filter != oldValue { scheduleReload() } } }
  let loader: PagedLoader<Item>

  @ObservationIgnored private let fetch: @MainActor (Filter, Int, Int) async throws -> ABCCore.Page<Item>
  @ObservationIgnored private var pending: Task<Void, Never>?

  init(filter: Filter, fetch: @escaping @MainActor (Filter, Int, Int) async throws -> ABCCore.Page<Item>) {
    self.filter = filter
    self.fetch = fetch
    loader = PagedLoader { page, size in try await fetch(filter, page, size) }
  }

  func start() async { if !loader.hasLoaded { await loader.refresh() } }

  /// Waits for typing to pause before hitting the network; a newer change replaces an older one.
  private func scheduleReload() {
    pending?.cancel()
    pending = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(250))
      guard !Task.isCancelled, let self else { return }
      let filter = self.filter, fetch = self.fetch
      await self.loader.reset { page, size in try await fetch(filter, page, size) }
    }
  }
}
