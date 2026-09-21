import Foundation

/// One file of bytes for a `multipart/form-data` upload.
struct UploadFile {
  let field: String
  let filename: String
  let mimeType: String
  let data: Data
}

/// The HTTP layer. Remember the API's conventions: ids and selectors go in the
/// query string on GET, and in the JSON body on POST, PUT and DELETE (yes, DELETE
/// carries a body); every JSON answer is an `APIEnvelope`.
///
/// Two jobs on every request beyond sending it:
///
/// 1. attach `Authorization: Bearer <token>` when a session exists;
/// 2. if a request that carried a token comes back 401, tell the session layer.
///    The token was revoked, expired, or the account was banned. A 401 on a
///    request with no token (a wrong password at login) is not a session event.
public final class APIClient: Sendable {
  private let session: URLSession
  private let baseURL: DevServerURL
  private let cache: SessionCache

  /// Sign-in, claim, and recovery are public. Sending a token there is pointless, and
  /// worse, their 401 ("wrong password") would be mistaken for "your session was
  /// revoked": checking the current password before a password change would sign
  /// the user out on a typo.
  private static let publicAuthPaths = ["auth/login", "auth/claim", "auth/recover"]

  public init(baseURL: DevServerURL, cache: SessionCache, configuration: URLSessionConfiguration = .ephemeral) {
    configuration.timeoutIntervalForRequest = 30
    configuration.httpCookieStorage = nil
    configuration.urlCache = nil
    self.session = URLSession(configuration: configuration)
    self.baseURL = baseURL
    self.cache = cache
  }

  typealias Query = [(String, String?)]

  /// `anonymous` sends the request without the session token, whoever is signed in. The offline
  /// directory download uses it, so the saved copy holds exactly what the public sees.
  func get<T: Decodable>(_ path: String, query: Query = [], anonymous: Bool = false) async throws -> APIEnvelope<T> {
    try decode(try await perform(request("GET", path, query: query, anonymous: anonymous)))
  }

  /// For the one endpoint that does not answer with an envelope (`/health`).
  func getPlain<T: Decodable>(_ path: String) async throws -> T {
    try decode(try await perform(request("GET", path)))
  }

  /// `headers` carries `Idempotency-Key` on the two requests that must never happen twice.
  func send<B: Encodable, T: Decodable>(_ method: String, _ path: String, body: B, headers: [String: String] = [:]) async throws -> APIEnvelope<T> {
    var r = try request(method, path)
    headers.forEach { r.setValue($1, forHTTPHeaderField: $0) }
    r.setValue("application/json", forHTTPHeaderField: "Content-Type")
    r.httpBody = try Self.encoder.encode(body)
    return try decode(try await perform(r))
  }

  /// For calls whose answer carries nothing the app uses.
  func send<B: Encodable>(_ method: String, _ path: String, body: B) async throws {
    let _: APIEnvelope<JSONValue> = try await send(method, path, body: body)
  }

  func download(_ path: String, query: Query) async throws -> Data {
    try await perform(request("GET", path, query: query))
  }

  func upload<T: Decodable>(_ path: String, fields: [(String, String)], file: UploadFile, headers: [String: String] = [:]) async throws -> APIEnvelope<T> {
    let boundary = "abcmailbox-\(UUID().uuidString)"
    var body = Data()
    for (name, value) in fields {
      body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
    }
    let filename = file.filename.replacingOccurrences(of: "\"", with: "_").replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
    body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(file.field)\"; filename=\"\(filename)\"\r\nContent-Type: \(file.mimeType)\r\n\r\n")
    body.append(file.data)
    body.append("\r\n--\(boundary)--\r\n")
    var r = try request("POST", path)
    headers.forEach { r.setValue($1, forHTTPHeaderField: $0) }
    r.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    r.httpBody = body
    r.timeoutInterval = 120
    return try decode(try await perform(r))
  }

  // MARK: - Plumbing

  private static let encoder: JSONEncoder = {
    let e = JSONEncoder()
    e.outputFormatting = [.withoutEscapingSlashes]
    return e
  }()

  private func request(_ method: String, _ path: String, query: Query = [], anonymous: Bool = false) throws -> URLRequest {
    guard var components = URLComponents(url: baseURL.current().appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
      throw AppError.unexpected("Bad URL for \(path)")
    }
    let items = query.compactMap { name, value in value.map { URLQueryItem(name: name, value: $0) } }
    if !items.isEmpty {
      components.queryItems = items
      // URLComponents leaves "+" alone, and the server reads "+" as a space.
      components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
    }
    guard let url = components.url else { throw AppError.unexpected("Bad URL for \(path)") }
    var r = URLRequest(url: url)
    r.httpMethod = method
    r.setValue("application/json", forHTTPHeaderField: "Accept")
    if !anonymous, !Self.publicAuthPaths.contains(where: { path.hasSuffix($0) }), let token = cache.token {
      r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
    return r
  }

  private func perform(_ request: URLRequest) async throws -> Data {
    let data: Data, response: URLResponse
    do {
      (data, response) = try await session.data(for: request)
    } catch {
      throw AppError.network
    }
    guard let http = response as? HTTPURLResponse else { throw AppError.unexpected("Not an HTTP response.") }
    guard (200..<300).contains(http.statusCode) else {
      if http.statusCode == 401, let sent = request.value(forHTTPHeaderField: "Authorization")?.dropFirst("Bearer ".count) {
        cache.reportUnauthorized(String(sent))
      }
      throw Self.error(status: http.statusCode, body: data, retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
    }
    return data
  }

  private func decode<T: Decodable>(_ data: Data) throws -> T {
    do {
      return try JSONDecoder().decode(T.self, from: data)
    } catch {
      throw AppError.unreadable(String(describing: error))
    }
  }

  /// The error body is still the API envelope, so it is parsed to recover `errors` or `info`.
  static func error(status: Int, body: Data, retryAfter: String?) -> AppError {
    let envelope = try? JSONDecoder().decode(APIEnvelope<JSONValue>.self, from: body)
    let info = envelope?.info ?? envelope?.error
    switch status {
    case 400:
      if let errors = envelope?.errors, !errors.isEmpty { return .validation(errors) }
      return .validation([info ?? "The request was rejected."])
    case 401: return .unauthorized(info)
    case 403: return .forbidden(info ?? "You are not allowed to do that.")
    // Like a 409, a 404 may carry the useful sentence in `error` ("Message 99999 not found") under a general `info`.
    case 404: return .notFound(envelope?.error ?? info)
    // Lifecycle refusals put the useful sentence in `error` ("A printed letter cannot move to queued"); `info` is generic.
    case 409: return .conflict(envelope?.error ?? info, name: envelope?.name)
    case 410: return .gone(info)
    // An Idempotency-Key reused for a different request (API PR #97). Retrying unchanged would get the
    // same answer, so it is a refusal, not a server fault.
    case 422: return .validation([envelope?.error ?? info ?? "The request was rejected."])
    case 429: return .rateLimited(info, retryAfterSeconds: retryAfter.flatMap { Int($0) })
    default: return .server(status: status, info: info)
    }
  }
}

private extension Data {
  mutating func append(_ string: String) { append(Data(string.utf8)) }
}
