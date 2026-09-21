import Foundation

/// Every JSON response from the API is `{ data, info, success, status, name }`.
/// Lists add `total`, `page`, `page_size`. Validation failures replace `data`
/// with `errors: [...]`, and controller-level 4xx responses may add `error`.
/// One type covers all of them so a single parser handles success and failure.
struct APIEnvelope<T: Decodable>: Decodable {
  let data: T?
  let info: String?
  let name: String?
  let errors: [String]?
  let error: String?
  /// On some refusals: a code for why (a claim token that is `expired` or `used`). Asked of the API; not sent yet, see `AppError.goneCondition`.
  let condition: String?
  let total: Int?
  let page: Int?
  let pageSize: Int?
  /// Only on the notification feed: how many entries the account has not read.
  let unread: Int?

  private enum CodingKeys: String, CodingKey { case data, info, name, errors, error, condition, total, page, unread, pageSize = "page_size" }

  /// The payload, or an error a screen can show when the server sent none.
  func required(_ what: String = "response") throws -> T {
    guard let data else { throw AppError.unexpected("The \(what) had no data.") }
    return data
  }
}

extension APIEnvelope {
  func toPage<Element>() -> Page<Element> where T == [Element] {
    let items = data ?? []
    return Page(items: items, total: total ?? items.count, page: page ?? 1, pageSize: pageSize ?? items.count)
  }
}

/// A list response with its paging fields, as repositories hand it to `PagedLoader`.
public struct Page<Item> {
  public let items: [Item]
  public let total: Int
  public let page: Int
  public let pageSize: Int

  public init(items: [Item], total: Int, page: Int, pageSize: Int) {
    self.items = items
    self.total = total
    self.page = page
    self.pageSize = pageSize
  }

  public var hasMore: Bool { page * pageSize < total }

  public func map<R>(_ transform: (Item) throws -> R) rethrows -> Page<R> {
    Page<R>(items: try items.map(transform), total: total, page: page, pageSize: pageSize)
  }
}
