@testable import ABCCore
import XCTest

final class APIClientTests: XCTestCase {

  private func client(token: String? = nil, _ handler: @escaping (Recorded) -> Stubbed) -> (APIClient, SessionCache, String) {
    let (configuration, id) = StubServer.configuration(handler: handler)
    let cache = SessionCache()
    cache.token = token
    return (APIClient(baseURL: DevServerURL(defaultURL: URL(string: "http://api.test/")!), cache: cache, configuration: configuration), cache, id)
  }

  private func failure(_ status: Int, _ body: String, headers: [String: String] = [:]) async -> AppError? {
    let (api, _, _) = client { _ in Stubbed(status: status, headers: headers, body: Data(body.utf8)) }
    do { let _: APIEnvelope<JSONValue> = try await api.get("anything"); return nil } catch { return error as? AppError }
  }

  func test400BecomesValidationWithTheErrorsList() async {
    let e = await failure(400, #"{"success":false,"errors":["Too short.","Email required."]}"#)
    XCTAssertEqual(e, .validation(["Too short.", "Email required."]))
    XCTAssertEqual(e?.userMessage, "Too short. Email required.")
  }

  func test403BecomesForbiddenCarryingInfoVerbatim() async {
    let info = "Your group is pending approval; an admin must activate it before you can send letters."
    let e = await failure(403, #"{"success":false,"info":"\#(info)","status":403}"#)
    XCTAssertEqual(e, .forbidden(info))
  }

  func test401And404And409And410MapToTheirCases() async {
    let unauthorized = await failure(401, #"{"success":false,"info":"Incorrect username or password."}"#)
    XCTAssertEqual(unauthorized, .unauthorized("Incorrect username or password."))
    let notFound = await failure(404, #"{"info":"No such prisoner."}"#)
    XCTAssertEqual(notFound, .notFound("No such prisoner."))
    let conflict = await failure(409, #"{"info":"Letters only move forward."}"#)
    XCTAssertEqual(conflict, .conflict("Letters only move forward."))
    let gone = await failure(410, #"{"info":"This claim token has expired."}"#)
    XCTAssertEqual(gone, .gone("This claim token has expired."))
  }

  func testALifecycle409ShowsTheSpecificSentenceFromErrorNotTheGenericInfo() async {
    let e = await failure(409, #"{"success":false,"name":"LetterStatusError","info":"Error updating letter status.","status":409,"error":"A printed letter cannot move to queued."}"#)
    XCTAssertEqual(e?.userMessage, "A printed letter cannot move to queued.")
  }

  func test429BecomesRateLimitedWithTheRetryAfterSeconds() async {
    let e = await failure(429, #"{"success":false,"name":"RateLimitError","info":"Too many sign-in attempts. Try again in 15 minute(s).","status":429}"#, headers: ["Retry-After": "900"])
    XCTAssertEqual(e, .rateLimited("Too many sign-in attempts. Try again in 15 minute(s).", retryAfterSeconds: 900))
    XCTAssertEqual(AppError.rateLimited(nil, retryAfterSeconds: 900).userMessage, "Too many attempts. Try again in 15 minute(s).")
  }

  func testAnUnparseableErrorBodyStillMapsByStatus() async {
    let e = await failure(500, "<html>nope</html>")
    XCTAssertEqual(e, .server(status: 500, info: nil))
    XCTAssertEqual(e?.readable, "Something went wrong. Please try again.")
  }

  func testAnUnreadableSuccessIsAnErrorNotACrash() async {
    let e = await failure(200, "<html>a captive portal</html>")
    guard case .unreadable = e else { return XCTFail("expected .unreadable, got \(String(describing: e))") }
    XCTAssertEqual(e?.meansNotReachingOurServer, true)
  }

  func testTheBearerTokenIsAttachedAndARefusedOneIsReported() async {
    let (api, cache, id) = client(token: "tok-A") { r in r.path == "/chat/chats" ? .error(401, info: "Token revoked.") : .data([:]) }
    let refused = expectation(description: "the refused token is reported")
    cache.onUnauthorized = { token in XCTAssertEqual(token, "tok-A"); refused.fulfill() }
    let _: APIEnvelope<JSONValue>? = try? await api.get("prisoner/prisoners")
    let _: APIEnvelope<JSONValue>? = try? await api.get("chat/chats")
    await fulfillment(of: [refused], timeout: 2)
    XCTAssertEqual(StubServer.requests(id).map { $0.headers["Authorization"] }, ["Bearer tok-A", "Bearer tok-A"])
  }

  func testSignInClaimAndRecoveryNeverCarryTheTokenSoTheir401IsNotASessionEvent() async {
    // Checking the current password before a password change must not sign the user out on a typo.
    let (api, cache, id) = client(token: "tok-A") { _ in .error(401, info: "Incorrect username or password.") }
    cache.onUnauthorized = { _ in XCTFail("a wrong password is not a revoked session") }
    for path in ["auth/login", "auth/claim", "auth/recover"] {
      do { try await api.send("POST", path, body: ["a": "b"]) } catch {}
    }
    XCTAssertEqual(StubServer.requests(id).compactMap { $0.headers["Authorization"] }, [])
  }

  func testOptionalFiltersAreLeftOutAndPlusSignsSurviveTheQueryString() async throws {
    let (api, _, id) = client { _ in .data([]) }
    let _: APIEnvelope<[PrisonerDTO]> = try await api.get("prisoner/prisoners", query: [("q", "a+b c"), ("status", nil), ("page", "2")])
    let r = try XCTUnwrap(StubServer.requests(id).first)
    XCTAssertEqual(r.path, "/prisoner/prisoners")
    XCTAssertEqual(r.query, ["q": "a+b c", "page": "2"])
  }

  func testDeleteCarriesAJSONBodyAndNilFieldsAreOmitted() async throws {
    let (api, _, id) = client { _ in .data([:]) }
    try await api.send("DELETE", "messaging/message", body: IdBody(id: 41))
    try await api.send("POST", "messaging/message", body: SendMessageRequest(messageText: "Hi", prisoner: 3, sender: "user", user: nil, relayChapter: nil))
    let requests = StubServer.requests(id)
    XCTAssertEqual(requests[0].method, "DELETE")
    XCTAssertEqual(requests[0].json as NSDictionary, ["id": 41])
    XCTAssertEqual(requests[0].headers["Content-Type"], "application/json")
    // Omitted, not null, so the server resolves the relay group itself.
    XCTAssertEqual(requests[1].json as NSDictionary, ["messageText": "Hi", "prisoner": 3, "sender": "user"])
  }

  func testAnUploadIsMultipartWithTheMessageIdTheNonceAndTheFile() async throws {
    let (api, _, id) = client { _ in .data(["id": 5, "message": 41, "originalName": "scan.pdf", "mimeType": "application/pdf", "size": 3]) }
    let envelope: APIEnvelope<AttachmentDTO> = try await api.upload("messaging/attachment", fields: [("message", "41"), ("nonce", "bm9uY2U=")], file: UploadFile(field: "file", filename: "scan.pdf", mimeType: "application/pdf", data: Data([1, 2, 3])))
    XCTAssertEqual(envelope.data?.id, 5)
    let r = try XCTUnwrap(StubServer.requests(id).first)
    XCTAssertTrue(try XCTUnwrap(r.headers["Content-Type"]).hasPrefix("multipart/form-data; boundary="))
    // Latin-1 maps bytes to characters one for one, so a binary multipart body can be searched as text.
    let text = try XCTUnwrap(String(data: r.body, encoding: .isoLatin1))
    XCTAssertTrue(text.contains("name=\"message\"\r\n\r\n41\r\n"))
    XCTAssertTrue(text.contains("name=\"nonce\"\r\n\r\nbm9uY2U=\r\n"))
    XCTAssertTrue(text.contains("name=\"file\"; filename=\"scan.pdf\"\r\nContent-Type: application/pdf\r\n\r\n\u{01}\u{02}\u{03}\r\n"))
  }

  func testRequestsFollowTheServerOverrideKeepingPathAndQuery() async throws {
    let (configuration, id) = StubServer.configuration { _ in .data([]) }
    let holder = DevServerURL(defaultURL: URL(string: "http://localhost:3000/")!)
    let api = APIClient(baseURL: holder, cache: SessionCache(), configuration: configuration)
    holder.update(URL(string: "http://192.168.1.20:8080/")!)
    let _: APIEnvelope<[PrisonerDTO]> = try await api.get("prisoner/prisoners", query: [("q", "ales"), ("page", "2")])
    let r = try XCTUnwrap(StubServer.requests(id).first)
    XCTAssertEqual(r.pathAndQuery, "/prisoner/prisoners?page=2&q=ales")
  }
}
