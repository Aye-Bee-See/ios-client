import Foundation

/// Any JSON value. The API has a few free-form fields (`address`, `location`,
/// `kdfParams`) and many responses whose `data` the app ignores; this decodes all of them.
public enum JSONValue: Codable, Equatable, Sendable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  public init(from decoder: Decoder) throws {
    if let c = try? decoder.container(keyedBy: AnyKey.self) {
      var out: [String: JSONValue] = [:]
      for key in c.allKeys { out[key.stringValue] = try c.decode(JSONValue.self, forKey: key) }
      self = .object(out)
    } else if var c = try? decoder.unkeyedContainer() {
      var out: [JSONValue] = []
      while !c.isAtEnd { out.append(try c.decode(JSONValue.self)) }
      self = .array(out)
    } else {
      let c = try decoder.singleValueContainer()
      if c.decodeNil() { self = .null }
      else if let b = try? c.decode(Bool.self) { self = .bool(b) }
      else if let n = try? c.decode(Double.self) { self = .number(n) }
      else { self = .string(try c.decode(String.self)) }
    }
  }

  public func encode(to encoder: Encoder) throws {
    switch self {
    case .null: var c = encoder.singleValueContainer(); try c.encodeNil()
    case .bool(let b): var c = encoder.singleValueContainer(); try c.encode(b)
    case .number(let n): var c = encoder.singleValueContainer(); try c.encode(n)
    case .string(let s): var c = encoder.singleValueContainer(); try c.encode(s)
    case .array(let a): var c = encoder.unkeyedContainer(); for v in a { try c.encode(v) }
    case .object(let o): var c = encoder.container(keyedBy: AnyKey.self); for (k, v) in o { try c.encode(v, forKey: AnyKey(k)) }
    }
  }

  /// The text of a string or number; nil for everything else. Used for free-form address fields.
  var text: String? {
    switch self {
    case .string(let s): return s
    case .number(let n): return n == n.rounded() && abs(n) < 1e15 ? String(Int64(n)) : String(n)
    case .bool(let b): return String(b)
    default: return nil
    }
  }

  /// Re-decodes this value as a concrete type (for example `kdfParams` as `KdfParams`).
  func decoded<T: Decodable>(as type: T.Type) throws -> T {
    try JSONDecoder().decode(T.self, from: JSONEncoder().encode(self))
  }

  private struct AnyKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(_ s: String) { stringValue = s }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
  }
}
