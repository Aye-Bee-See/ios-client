@testable import ABCCore
import XCTest

/// A stand-in for the public API's three lists, paged the way the server pages them, with a switch for "no signal".
private final class DirectoryServer: @unchecked Sendable {
  var prisoners: [[String: Any]] = []
  var facilities: [[String: Any]] = []
  var groups: [[String: Any]] = []
  var noSignal = false
  var captivePortal = false
  /// One shot: answer this path with this instead.
  var refusal: (path: String, answer: Stubbed)?

  func handle(_ r: Recorded) -> Stubbed {
    if noSignal { return Stubbed(status: -1) }
    if captivePortal { return .text("<html><body>Welcome to Community Centre WiFi. Accept the terms to continue.</body></html>") }
    if let refusal, refusal.path == r.path { self.refusal = nil; return refusal.answer }
    func paged(_ rows: [[String: Any]]) -> Stubbed {
      let page = Int(r.query["page"] ?? "1") ?? 1, size = Int(r.query["page_size"] ?? "20") ?? 20
      return .data(Array(rows.dropFirst((page - 1) * size).prefix(size)), extra: ["total": rows.count, "page": page, "page_size": size])
    }
    func one(_ rows: [[String: Any]]) -> Stubbed {
      rows.first { $0["id"] as? Int == Int(r.query["id"] ?? "") }.map { .data($0) } ?? .error(404, info: "Not found")
    }
    switch r.path {
    case "/prisoner/prisoners": return paged(prisoners)
    case "/prison/prisons": return paged(facilities)
    case "/chapter/chapters": return paged(groups)
    case "/prisoner/prisoner": return one(prisoners)
    case "/prison/prison": return one(facilities)
    case "/chapter/chapter": return one(groups)
    case "/prison/mail-rules": return .data(["categories": ["photos"], "rules": [["tag": "no_photos", "category": "photos", "label": "No pictures (as the server words it)"]]])
    case "/health": return .json(["status": "ok", "encryptionMode": "server"])
    case "/auth/login": return .data(loginJSON(id: 9, username: "member1", role: "chapter", chapterId: 1))
    default: return .error(404, info: "no \(r.path)")
    }
  }
}

@MainActor
final class OfflineDirectoryTests: XCTestCase {
  private var server: DirectoryServer!
  private var app: TestApp!
  private var offline: OfflineDirectory { app.container.offline }
  private var directory: DirectoryRepository { app.container.directory }

  private func prisoner(_ id: Int, chosen: String?, birth: String?, status: String = "incarcerated", country: String = "United States", featured: Bool = false, facility: Int = 1) -> [String: Any] {
    ["id": id, "chosenName": chosen ?? NSNull(), "birthName": birth ?? NSNull(), "status": status, "country": country, "featured": featured, "prison": facility, "createdAt": "2026-01-0\(id)T00:00:00.000Z"]
  }
  private func group(_ id: Int, _ name: String, services: [String], role: String, status: String = "active") -> [String: Any] {
    ["id": id, "name": name, "country": "United States", "services": services, "networkRole": role, "accountStatus": status]
  }

  override func setUp() async throws {
    server = DirectoryServer()
    server.prisoners = [
      prisoner(1, chosen: "Jane Smith", birth: "John Smith", featured: true),
      prisoner(2, chosen: nil, birth: "alex johnson", status: "pretrial", facility: 2),
      prisoner(3, chosen: "Zed", birth: "Michael Smithson", country: "Belarus", facility: 2),
    ]
    server.facilities = [
      ["id": 1, "prisonName": "Test Prison", "country": "United States", "routing": "direct", "mailRules": ["no_photos"], "createdAt": "2026-01-01T00:00:00.000Z",
       "relay_groups": [group(1, "Test Chapter", services: [], role: "both")]],
      ["id": 2, "prisonName": "Alpha Prison", "country": "United States", "routing": "relay_only", "createdAt": "2026-02-01T00:00:00.000Z",
       "relay_groups": [group(4, "Suspended", services: [], role: "relay", status: "suspended")]],
    ]
    server.groups = [
      group(1, "Test Chapter", services: ["letter_writing_nights", "legal_support"], role: "both"),
      group(2, "Relay Only", services: ["international_relay"], role: "relay"),
      group(3, "Collectors", services: ["legal"], role: "collecting"),
    ]
    let server = server!
    app = TestApp { server.handle($0) }
  }

  private func ids(_ filter: (inout PrisonerFilter) -> Void = { _ in }) -> [Int] {
    var f = PrisonerFilter(); filter(&f)
    return offline.prisoners(f, page: 1, pageSize: 20)?.items.map(\.id) ?? []
  }

  // The offline directory must answer a search the way the server would, or a volunteer gets different
  // results in the basement than at home. These mirror Android's DirectoryCacheDaoTest case for case.

  func testNothingIsSavedUntilADownloadAndThenTheCountsSayWhatIsThere() async throws {
    XCTAssertNil(offline.savedAt)
    XCTAssertNil(offline.prisoners(PrisonerFilter(), page: 1, pageSize: 20))
    try await offline.download()
    XCTAssertNotNil(offline.savedAt)
    XCTAssertEqual(offline.counts, DirectoryCounts(prisoners: 3, facilities: 2, groups: 3))
  }

  func testSearchMatchesBirthOrChosenNameAsASubstringWhateverTheCase() async throws {
    try await offline.download()
    XCTAssertEqual(ids { $0.query = "smith" }, [1, 3]) // "Jane Smith"/"John Smith", and "Michael Smithson" by birth name
    XCTAssertEqual(ids { $0.query = " John SMITH " }, [1]) // birth name only
    XCTAssertEqual(ids { $0.query = "johnson" }, [2])
    var f = PrisonerFilter(); f.query = "smith"
    XCTAssertEqual(offline.prisoners(f, page: 1, pageSize: 20)?.total, 2)
  }

  func testFiltersCombineAndANilFilterMeansAny() async throws {
    try await offline.download()
    XCTAssertEqual(ids { $0.status = "pretrial" }, [2])
    XCTAssertEqual(ids { $0.country = "Belarus" }, [3])
    XCTAssertEqual(ids { $0.featured = true }, [1])
    XCTAssertEqual(ids { $0.featured = false }, [2, 3])
    XCTAssertEqual(ids { $0.facilityId = 2 }.sorted(), [2, 3])
    XCTAssertEqual(ids { $0.query = "smith"; $0.status = "pretrial" }, [])
    XCTAssertEqual(ids { $0.query = "smith"; $0.facilityId = 2 }, [3])
  }

  func testSortsByNameWithoutRegardToCaseByNewestByOldestAndByIdOtherwise() async throws {
    try await offline.download()
    XCTAssertEqual(ids { $0.sort = "name" }, [2, 1, 3]) // alex johnson, Jane Smith, Zed
    XCTAssertEqual(ids { $0.sort = "newest" }, [3, 2, 1])
    XCTAssertEqual(ids { $0.sort = "oldest" }, [1, 2, 3])
    XCTAssertEqual(ids { $0.sort = "something the app does not know" }, [1, 2, 3])
  }

  func testPagesDoNotOverlap() async throws {
    try await offline.download()
    let first = try XCTUnwrap(offline.prisoners(PrisonerFilter(), page: 1, pageSize: 2)), second = try XCTUnwrap(offline.prisoners(PrisonerFilter(), page: 2, pageSize: 2))
    XCTAssertEqual(first.items.count, 2); XCTAssertEqual(second.items.count, 1)
    XCTAssertEqual(Set((first.items + second.items).map(\.id)).count, 3)
    XCTAssertTrue(first.hasMore); XCTAssertFalse(second.hasMore)
  }

  func testFacilitiesFilterByRoutingAndByHavingAnActiveRelayGroup() async throws {
    try await offline.download()
    func ids(_ filter: (inout FacilityFilter) -> Void) -> [Int] { var f = FacilityFilter(); filter(&f); return offline.facilities(f, page: 1, pageSize: 20)?.items.map(\.id) ?? [] }
    XCTAssertEqual(ids { $0.routing = "relay_only" }, [2])
    XCTAssertEqual(ids { $0.relay = true }, [1])
    XCTAssertEqual(ids { $0.relay = false }, [2], "a suspended relay group is not a relay group")
    XCTAssertEqual(ids { $0.query = "alpha" }, [2])
  }

  func testAServiceMatchesAWholeKeyNeverHalfOfOneAndBothAnswersToEitherRole() async throws {
    try await offline.download()
    func ids(_ filter: (inout GroupFilter) -> Void) -> [Int] { var f = GroupFilter(); filter(&f); return offline.groups(f, page: 1, pageSize: 20)?.items.map(\.id) ?? [] }
    XCTAssertEqual(ids { $0.service = "legal" }, [3]) // not "legal_support"
    XCTAssertEqual(ids { $0.service = "legal_support" }, [1])
    XCTAssertEqual(ids { $0.networkRole = "relay" }, [2, 1]) // Relay Only, Test Chapter (both)
    XCTAssertEqual(ids { $0.networkRole = "collecting" }, [3, 1])
  }

  func testTheDownloadWalksEveryPageAndIsAnonymousWhoeverIsSignedIn() async throws {
    server.prisoners = (1...250).map { prisoner($0, chosen: "Prisoner \($0)", birth: nil) }
    try await app.container.sessions.login(username: "member1", password: "password1")
    try await offline.download()
    XCTAssertEqual(offline.counts.prisoners, 250)
    let pages = app.requests(to: "/prisoner/prisoners")
    XCTAssertEqual(pages.map { $0.query["page"] }, ["1", "2", "3"])
    XCTAssertEqual(Set(pages.map { $0.query["page_size"] }), ["100"]); XCTAssertEqual(Set(pages.map { $0.query["full"] }), ["true"])
    // A group member sees unpublished records. They must not reach a file that outlives the session.
    let download = app.requests.filter { $0.query["full"] == "true" || $0.path == "/prison/mail-rules" }
    XCTAssertEqual(download.compactMap { $0.headers["Authorization"] }, [])
    // The same person's ordinary reads do carry the token.
    _ = try await directory.prisoner(id: 1)
    XCTAssertNotNil(app.requests(to: "/prisoner/prisoner").last?.headers["Authorization"])
  }

  func testANewDownloadReplacesTheOldOneWholeAndAFailedOneChangesNothing() async throws {
    try await offline.download()
    let firstSavedAt = offline.savedAt
    server.refusal = ("/chapter/chapters", .error(500, info: "Down."))
    server.prisoners = [prisoner(9, chosen: "Only One", birth: nil)]
    await assertThrowsAppError(try await offline.download())
    XCTAssertEqual(ids(), [2, 1, 3], "a download that fails part-way has written nothing")
    XCTAssertEqual(offline.savedAt, firstSavedAt)

    try await offline.download()
    XCTAssertEqual(ids(), [9])
    XCTAssertEqual(offline.counts, DirectoryCounts(prisoners: 1, facilities: 2, groups: 3))
  }

  func testTheCopySurvivesARelaunchAndARecordTheAppCannotReadCostsOnlyItself() async throws {
    server.prisoners.append(["id": "not a number", "chosenName": "Broken row"])
    try await offline.download()
    XCTAssertEqual(offline.counts.prisoners, 3)
    let server = server!
    let relaunched = TestApp(scratch: app.scratch) { server.handle($0) }
    XCTAssertEqual(relaunched.container.offline.counts, DirectoryCounts(prisoners: 3, facilities: 2, groups: 3))
    XCTAssertEqual(relaunched.container.offline.prisoner(id: 3)?.birthName, "Michael Smithson")
  }

  func testHousekeepingDownloadsOnlyWhenThereIsNoCopyOrItIsOld() async throws {
    await offline.downloadIfOlderThan(hours: 24)
    XCTAssertNotNil(offline.savedAt)
    let requests = app.requests.count
    await offline.downloadIfOlderThan(hours: 24)
    XCTAssertEqual(app.requests.count, requests, "a fresh copy is left alone")
    await offline.downloadIfOlderThan(hours: 0)
    XCTAssertGreaterThan(app.requests.count, requests)
    server.noSignal = true
    await offline.downloadIfOlderThan(hours: 0) // silent: this is housekeeping
    XCTAssertEqual(offline.counts.prisoners, 3)
  }

  // Without a connection ------------------------------------------------------------------------------

  func testWithNoConnectionASavedRecordIsShownAndTheRepositorySaysItIsTheSavedCopy() async throws {
    try await offline.download()
    server.noSignal = true
    let f = try await directory.facility(id: 1)
    XCTAssertEqual(f.name, "Test Prison")
    XCTAssertEqual(f.rules.rules.map(\.label), ["No pictures (as the server words it)"], "the rule list saved with the copy names the rule")
    XCTAssertEqual(f.relayGroups.map(\.name), ["Test Chapter"], "a saved list row is as full as a single read")
    XCTAssertEqual(directory.source, .saved(at: try XCTUnwrap(offline.savedAt)))

    var smiths = PrisonerFilter(); smiths.query = "smith"
    let page = try await directory.prisoners(smiths, page: 1, pageSize: 20)
    XCTAssertEqual(page.items.map(\.name), ["Jane Smith", "Zed"])
  }

  func testWithNoConnectionAndNothingSavedTheScreenGetsTheNetworkErrorNotAnEmptyPage() async throws {
    server.noSignal = true
    await assertThrowsAppError(try await directory.facility(id: 2)) { XCTAssertEqual($0, .network) }
    await assertThrowsAppError(try await directory.prisoners(PrisonerFilter(), page: 1, pageSize: 20)) { XCTAssertEqual($0, .network) }
    server.noSignal = false
    try await offline.download()
    server.noSignal = true
    // A copy exists, but this record is not in it.
    await assertThrowsAppError(try await directory.prisoner(id: 99)) { XCTAssertEqual($0, .network) }
    XCTAssertEqual(directory.source, .live)
  }

  func testTheServersOwnRefusalStandsEvenWhenThePhoneHasACopyOfTheRecord() async throws {
    try await offline.download()
    server.refusal = ("/prisoner/prisoner", .error(404, info: "Prisoner 1 not found")) // withdrawn since the download
    await assertThrowsAppError(try await directory.prisoner(id: 1)) { XCTAssertTrue($0.isNotFound) }
    XCTAssertEqual(directory.source, .live)
  }

  func testAReadThatReachesTheServerAgainFlipsTheSourceBackToLive() async throws {
    try await offline.download()
    server.noSignal = true
    let saved = try await directory.featuredPrisoners()
    XCTAssertEqual(saved.map(\.name), ["Jane Smith"])
    guard case .saved = directory.source else { return XCTFail("expected the saved copy") }
    server.noSignal = false
    _ = try await directory.featuredPrisoners()
    XCTAssertEqual(directory.source, .live)
  }

  func testAWifiLoginPageAnsweringInPlaceOfTheAPICountsAsNoConnection() async throws {
    try await offline.download()
    server.captivePortal = true
    let f = try await directory.facility(id: 2)
    XCTAssertEqual(f.name, "Alpha Prison")
    guard case .saved = directory.source else { return XCTFail("expected the saved copy") }
  }
}
