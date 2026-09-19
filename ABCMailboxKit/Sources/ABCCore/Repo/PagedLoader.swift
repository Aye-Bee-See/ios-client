import Foundation
import Observation

/// A list that loads itself a page at a time over the API's 1-based `page` /
/// `page_size` endpoints. One class serves every list: the caller supplies the
/// request as a function. It plays the part Paging 3 plays on Android.
///
/// A view shows `items`, calls `loadMoreIfNeeded` as rows appear, and renders
/// `phase` for the three states every list needs: first load (spinner or
/// error), empty, and "loading more" at the bottom.
@MainActor @Observable
public final class PagedLoader<Item: Identifiable & Sendable> {
  public enum Phase: Equatable {
    case idle
    case loadingFirst
    case loadingMore
    case failedFirst(AppError)
    case failedMore(AppError)
  }

  public typealias Fetch = @MainActor (_ page: Int, _ pageSize: Int) async throws -> Page<Item>

  public private(set) var items: [Item] = []
  public private(set) var phase: Phase = .idle
  /// False until the first page has arrived, so "empty" is not shown before anything was asked.
  public private(set) var hasLoaded = false

  @ObservationIgnored private var fetch: Fetch
  @ObservationIgnored private let pageSize: Int
  @ObservationIgnored private var nextPage: Int? = 1
  /// Goes up whenever the list restarts, so an answer to an older question is dropped.
  @ObservationIgnored private var generation = 0

  // page_size is capped at 100 by the API; 20 keeps first paint quick on a phone.
  public init(pageSize: Int = 20, fetch: @escaping Fetch) {
    self.pageSize = pageSize
    self.fetch = fetch
  }

  public var isEmpty: Bool { hasLoaded && items.isEmpty && phase == .idle }

  /// Start over with a different request (the filter changed). The old rows go at once.
  public func reset(fetch: @escaping Fetch) async {
    self.fetch = fetch
    items = []
    hasLoaded = false
    await refresh()
  }

  /// Reload from the first page. Rows already on screen stay until the new ones arrive.
  public func refresh() async {
    generation += 1
    let mine = generation
    if items.isEmpty { phase = .loadingFirst }
    do {
      let page = try await fetch(1, pageSize)
      guard mine == generation else { return }
      items = page.items
      nextPage = page.hasMore && !page.items.isEmpty ? 2 : nil
      hasLoaded = true
      phase = .idle
    } catch {
      guard mine == generation else { return }
      if items.isEmpty { phase = .failedFirst(.from(error)) } else { phase = .idle }
    }
  }

  /// Call when `item` appears; near the end of what is loaded, the next page is fetched.
  public func loadMoreIfNeeded(current item: Item) async {
    guard let index = items.firstIndex(where: { $0.id == item.id }), index >= items.count - 5 else { return }
    await loadMore()
  }

  /// Also the retry for a failed "load more".
  public func loadMore() async {
    guard let page = nextPage, phase == .idle || isFailedMore else { return }
    let mine = generation
    phase = .loadingMore
    do {
      let result = try await fetch(page, pageSize)
      guard mine == generation else { return }
      let known = Set(items.map(\.id))
      items += result.items.filter { !known.contains($0.id) }
      nextPage = result.hasMore && !result.items.isEmpty ? page + 1 : nil
      phase = .idle
    } catch {
      guard mine == generation else { return }
      phase = .failedMore(.from(error))
    }
  }

  private var isFailedMore: Bool { if case .failedMore = phase { return true } else { return false } }
}
