import Foundation

/// ISO-8601 instants from the API ("2026-09-17T21:25:48.524Z"); anything unparseable becomes nil rather than a crash.
func parseInstant(_ text: String) -> Date? {
  // The formatters are not thread safe to mutate, but parsing with a configured one is.
  if let d = isoWithFraction.date(from: text) { return d }
  return isoPlain.date(from: text)
}

private let isoWithFraction: ISO8601DateFormatter = {
  let f = ISO8601DateFormatter()
  f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  return f
}()

private let isoPlain: ISO8601DateFormatter = {
  let f = ISO8601DateFormatter()
  f.formatOptions = [.withInternetDateTime]
  return f
}()

extension Optional where Wrapped == String {
  var instant: Date? { flatMap(parseInstant) }
  /// A date-only fact (detained since, release date): midnight UTC of the instant's UTC day.
  var utcDay: Date? { instant.map { Calendar.utc.startOfDay(for: $0) } }
}
