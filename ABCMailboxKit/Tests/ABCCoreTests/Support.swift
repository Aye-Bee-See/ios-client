@testable import ABCCore
import ABCCrypto
import Foundation
import XCTest

func fixtureData(_ name: String) throws -> Data {
  try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"), "missing fixture \(name)"))
}

func decodeFixture<T: Decodable>(_ name: String, as type: T.Type = T.self) throws -> T {
  try XCTUnwrap(JSONDecoder().decode(APIEnvelope<T>.self, from: fixtureData(name)).data)
}

/// One request as the stub server saw it.
struct Recorded {
  let method: String
  let path: String
  let query: [String: String]
  let headers: [String: String]
  let body: Data

  var json: [String: Any] { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:] }
  var bodyText: String { String(decoding: body, as: UTF8.self) }
  var pathAndQuery: String { query.isEmpty ? path : path + "?" + query.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "&") }
}

struct Stubbed {
  var status = 200
  var headers: [String: String] = [:]
  var body = Data()

  static func json(_ object: Any, status: Int = 200, headers: [String: String] = [:]) -> Stubbed {
    Stubbed(status: status, headers: headers, body: try! JSONSerialization.data(withJSONObject: object))
  }
  /// The API's envelope around `data`.
  static func data(_ data: Any, extra: [String: Any] = [:]) -> Stubbed {
    json(["data": data, "success": true, "status": 200].merging(extra) { $1 })
  }
  static func text(_ text: String, status: Int = 200) -> Stubbed { Stubbed(status: status, body: Data(text.utf8)) }
  static func error(_ status: Int, info: String? = nil, extra: [String: Any] = [:]) -> Stubbed {
    var o: [String: Any] = ["success": false, "status": status]
    if let info { o["info"] = info }
    return json(o.merging(extra) { $1 }, status: status)
  }
}

/// Stands in for the API: a `URLProtocol` that answers from a closure and remembers what it was asked.
/// Plays the part MockWebServer plays in the Android tests.
final class StubServer: URLProtocol, @unchecked Sendable {
  private static let lock = NSLock()
  private static var handlers: [String: (Recorded) -> Stubbed] = [:]
  private static var recordings: [String: [Recorded]] = [:]

  /// A configuration whose requests all come to `handler`. Each test gets its own server id, so tests may run side by side.
  static func configuration(id: String = UUID().uuidString, handler: @escaping (Recorded) -> Stubbed) -> (URLSessionConfiguration, String) {
    lock.withLock { handlers[id] = handler; recordings[id] = [] }
    let c = URLSessionConfiguration.ephemeral
    c.protocolClasses = [StubServer.self]
    c.httpAdditionalHeaders = ["X-Stub-Server": id]
    return (c, id)
  }

  static func requests(_ id: String) -> [Recorded] { lock.withLock { recordings[id] ?? [] } }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func stopLoading() {}

  override func startLoading() {
    let id = request.value(forHTTPHeaderField: "X-Stub-Server") ?? ""
    let url = request.url!
    var body = request.httpBody ?? Data()
    if let stream = request.httpBodyStream {
      stream.open()
      var buffer = [UInt8](repeating: 0, count: 65_536)
      while stream.hasBytesAvailable {
        let n = stream.read(&buffer, maxLength: buffer.count)
        if n <= 0 { break }
        body.append(buffer, count: n)
      }
      stream.close()
    }
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    let recorded = Recorded(
      method: request.httpMethod ?? "GET", path: url.path,
      query: Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 }),
      headers: request.allHTTPHeaderFields ?? [:], body: body
    )
    let handler = Self.lock.withLock { () -> ((Recorded) -> Stubbed)? in
      Self.recordings[id, default: []].append(recorded)
      return Self.handlers[id]
    }
    let answer = handler?(recorded) ?? .error(500, info: "no stub")
    // A negative status stands for "no signal": the request fails the way it does on a phone without a connection.
    if answer.status < 0 {
      client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
      return
    }
    let response = HTTPURLResponse(url: url, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: answer.headers.merging(["Content-Type": "application/json"]) { a, _ in a })!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: answer.body)
    client?.urlProtocolDidFinishLoading(self)
  }
}

/// A whole app, wired exactly as in production, talking to a stub server and keeping its secrets in memory.
@MainActor
struct TestApp {
  let container: AppContainer
  let serverId: String
  let secrets: InMemorySecretStore
  let defaults: UserDefaults
  let scratch: URL

  init(secrets: InMemorySecretStore = InMemorySecretStore(), defaults: UserDefaults? = nil, scratch: URL? = nil, handler: @escaping (Recorded) -> Stubbed) {
    let (configuration, id) = StubServer.configuration(handler: handler)
    let suite = "abc-tests-\(UUID().uuidString)"
    let defaults = defaults ?? UserDefaults(suiteName: suite)!
    // Not a fresh install, or the container would wipe the secrets a test put there on purpose.
    defaults.set(true, forKey: "has_launched")
    self.scratch = scratch ?? FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
    let scratch = self.scratch
    container = AppContainer(
      defaultBaseURL: URL(string: "http://api.test/")!, secrets: secrets, defaults: defaults, configuration: configuration,
      files: LocalFiles(root: scratch.appendingPathComponent("caches")), draftsDirectory: scratch.appendingPathComponent("drafts"),
      offlineDirectory: scratch.appendingPathComponent("offline"), outboxDirectory: scratch.appendingPathComponent("outbox")
    )
    serverId = id
    self.secrets = secrets
    self.defaults = defaults
  }

  var requests: [Recorded] { StubServer.requests(serverId) }
  func requests(to path: String, method: String? = nil) -> [Recorded] { requests.filter { $0.path == path && (method == nil || $0.method == method) } }
}

func assertThrowsAppError<T>(_ expression: @autoclosure () async throws -> T, file: StaticString = #filePath, line: UInt = #line, _ check: (AppError) -> Void = { _ in }) async {
  do {
    _ = try await expression()
    XCTFail("expected an AppError", file: file, line: line)
  } catch let e as AppError {
    check(e)
  } catch {
    XCTFail("expected an AppError, got \(error)", file: file, line: line)
  }
}

func userJSON(id: Int, username: String, role: String = "user", chapterId: Int? = nil, name: String? = nil) -> [String: Any] {
  ["id": id, "username": username, "role": role, "chapterId": chapterId as Any? ?? NSNull(), "name": name as Any? ?? NSNull(), "email": NSNull()]
}

func loginJSON(id: Int, username: String, role: String = "user", chapterId: Int? = nil, token: String = "token-1", keys: [String: Any]? = nil) -> [String: Any] {
  var data: [String: Any] = ["user": userJSON(id: id, username: username, role: role, chapterId: chapterId), "token": ["token": token, "expires": 1_800_000_000_000.0]]
  if let keys { data["keys"] = keys }
  return data
}
