import Foundation

// The account's notification feed (API PR #96). Entries hold ids and states, never letter content.

struct NotificationDTO: Decodable {
  let id: Int
  let event: String
  let chat: Int?
  let message: Int?
  /// `{"status": "mailed"}`, `{"status": "approved", "resource": "prison"}`, or nothing.
  let detail: [String: JSONValue]?
  let readAt: String?
}

/// `{}` marks everything read; the API also takes `ids` or `upTo`, which this app has no use for.
struct MarkReadRequest: Encodable {}

struct MarkedReadDTO: Decodable {
  let unread: Int?
}
