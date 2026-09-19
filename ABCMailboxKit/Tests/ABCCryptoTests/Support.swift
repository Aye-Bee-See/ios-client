import Foundation
import XCTest

func fixtureURL(_ name: String) throws -> URL {
  try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"), "missing fixture \(name)")
}

/// Walks a parsed JSON object by keys, as the Android tests do with `s("letter", "body")`.
struct JSONFixture {
  let root: [String: Any]

  init(_ name: String) throws {
    root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL(name))) as? [String: Any])
  }

  func object(_ path: String...) throws -> [String: Any] {
    try path.reduce(root) { o, k in try XCTUnwrap(o[k] as? [String: Any], "no object at \(k)") }
  }

  func string(_ path: String...) throws -> String {
    let parent = try path.dropLast().reduce(root) { o, k in try XCTUnwrap(o[k] as? [String: Any], "no object at \(k)") }
    return try XCTUnwrap(parent[path.last!] as? String, "no string at \(path)")
  }
}
