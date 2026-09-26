@testable import ABCCore
import XCTest

/// Pen names, and the limits on changing one (API #127).
@MainActor
final class PenNamesTests: XCTestCase {
  private var fake: FakeAPI!
  private var app: TestApp!
  private var penNames: PenNameRepository { app.container.penNames }

  override func setUp() async throws {
    fake = FakeAPI()
    var writer = FakeAPI.Account(id: 4, username: "user1", password: "password1")
    writer.penName = "James Hollow"
    fake.accounts = [writer]
    let fake = fake!
    app = TestApp { fake.handle($0) }
    try await app.container.sessions.login(username: "user1", password: "password1")
  }

  func testTheShapeIsCheckedOnThePhoneTheWayTheServerStoresIt() {
    XCTAssertEqual(PenName.normalise("  James   Hollow "), "James Hollow")
    XCTAssertNil(PenName.problem("Émile d'Arc-Ö. 2"))
    XCTAssertEqual(PenName.problem("Jo"), "A pen name has at least 3 characters.")
    XCTAssertEqual(PenName.problem(String(repeating: "a", count: 41)), "A pen name has at most 40 characters.")
    XCTAssertEqual(PenName.problem("3 Jays"), "A pen name starts with a letter.")
    XCTAssertEqual(PenName.problem("Jay@home"), "@ cannot be in a pen name.")
  }

  func testTheLimitsAreReadBeforeAnyoneTypes() async throws {
    fake.penNameLimits = ["changeAllowedAt": "2026-12-01T10:00:00.000Z", "newNamesLeft": 1, "newNamesWindowEnds": "2027-06-01T10:00:00.000Z", "cooldownDays": 90, "newPerYear": 2]
    let names = try await penNames.names()
    XCTAssertEqual(names.current, "James Hollow")
    XCTAssertEqual(names.names.map(\.name), ["James Hollow"])
    XCTAssertEqual(names.newNamesLeft, 1); XCTAssertEqual(names.cooldownDays, 90)
    let allowed = try XCTUnwrap(names.changeAllowedAt)
    XCTAssertFalse(names.canChange(at: allowed.addingTimeInterval(-1)))
    XCTAssertTrue(names.canChange(at: allowed))
    XCTAssertTrue(names.isCurrent("james  hollow"))
  }

  func testAnAccountThatNeverChoseMayChooseAtOnce() async throws {
    fake.accounts[0].penName = nil
    let names = try await penNames.names()
    XCTAssertNil(names.current); XCTAssertNil(names.changeAllowedAt); XCTAssertTrue(names.canChange())
    let saved = try await penNames.set(" Ada  Lovelace ")
    XCTAssertEqual(saved, "Ada Lovelace")
    XCTAssertEqual(app.requests(to: "/auth/user", method: "PUT").last?.json as NSDictionary?, ["id": 4, "penName": "Ada Lovelace"])
  }

  func testARefusalOverTheLimitsSaysWhichLimit() async throws {
    fake.penNameRefusal = ("cooldown", "A pen name may be changed once every 90 days: this one may change again on 2026-12-01.")
    await assertThrowsAppError(try await penNames.set("Ada Lovelace")) { XCTAssertEqual($0.penNameLimit, "cooldown") }
    fake.penNameRefusal = ("new_names", "This account has taken its 2 new pen name(s) for the year.")
    await assertThrowsAppError(try await penNames.set("Ada Lovelace")) { XCTAssertEqual($0.penNameLimit, "new_names") }
    XCTAssertNil(AppError.conflict("x", name: "KeyVersionError").penNameLimit)
  }
}
