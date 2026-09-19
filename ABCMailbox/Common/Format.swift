import Foundation

/// Dates the way the reader's region writes them ("19 September 2026", "September 19, 2026").
enum Format {
  static func long(_ date: Date) -> String { date.formatted(.dateTime.day().month(.wide).year()) }
  static func short(_ date: Date) -> String { date.formatted(.dateTime.day().month(.abbreviated).year()) }

  /// For facts that are a day, not a moment (detained since): the API's instant, read as its UTC day.
  static func longDay(_ date: Date) -> String {
    var style = Date.FormatStyle.dateTime.day().month(.wide).year()
    style.timeZone = TimeZone(identifier: "UTC")!
    return date.formatted(style)
  }

  /// "Verified 12 Jun 2026 (3 months ago)" or "Not yet verified".
  static func verificationLine(_ at: Date?) -> String {
    guard let at else { return "Not yet verified" }
    let months = Calendar.current.dateComponents([.month], from: Calendar.current.startOfDay(for: at), to: Calendar.current.startOfDay(for: Date())).month ?? 0
    let ago = months <= 0 ? "this month" : months == 1 ? "1 month ago" : "\(months) months ago"
    return "Verified \(short(at)) (\(ago))"
  }

  static func plural(_ count: Int, _ singular: String) -> String { "\(count) \(singular)\(count == 1 ? "" : "s")" }
}
