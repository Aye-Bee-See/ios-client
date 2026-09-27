@testable import ABCCore
import XCTest

/// A refusal's reasons, put under the fields a form shows (API #133), in the app's words where the code allows.
@MainActor
final class FormErrorsTests: XCTestCase {
  private let account = ["username": "username", "email": "email address", "name": "name", "penName": "pen name"]

  func testEachProblemGoesUnderItsFieldInTheAppsWords() {
    let e = AppError.validation(["That username is taken.", "Email must be in traditional email format. E.g. x@y.z", "penName must be between 3 and 40 characters."], problems: [
      FieldProblem(field: "username", code: "not_unique", message: "That username is taken."),
      FieldProblem(field: "email", code: "not_an_email", message: "Email must be in traditional email format. E.g. x@y.z"),
      FieldProblem(field: "penName", code: "length_out_of_range", min: 3, max: 40, message: "penName must be between 3 and 40 characters."),
    ])
    let f = FormErrors(e, fields: account)
    XCTAssertEqual(f.byField["username"], "That username is already taken. Choose another.")
    XCTAssertEqual(f.byField["email"], "That does not look like an email address.")
    XCTAssertEqual(f.byField["penName"], "Pen name must be 3 to 40 characters.")
    XCTAssertEqual(f.general, "Check the fields marked in red.", "everything landed under a field")
  }

  func testWhatNoFieldShowsAndValidationFailedKeepTheAPIsSentence() {
    let e = AppError.validation(["Username already in use.", "penName may hold letters, digits, spaces, hyphens, apostrophes, and dots, and starts with a letter.", "With authScheme \"split\", password is the auth key."], problems: [
      FieldProblem(field: "username", code: "not_unique", message: "Username already in use."),
      FieldProblem(field: "penName", code: "validation_failed", message: "penName may hold letters, digits, spaces, hyphens, apostrophes, and dots, and starts with a letter."),
      FieldProblem(field: nil, code: "not_an_auth_key", message: "With authScheme \"split\", password is the auth key."),
    ])
    let f = FormErrors(e, fields: ["username": "username"])
    XCTAssertEqual(f.byField, ["username": "That username is already taken. Choose another."])
    XCTAssertEqual(f.general, "penName may hold letters, digits, spaces, hyphens, apostrophes, and dots, and starts with a letter. This version of the app sent something the server could not use. Update the app, then try again.",
                   "a field this form does not show, and a client bug, go in the general line; validation_failed shows the API's sentence")
  }

  func testAGroupsFieldsAreFoundByTheirPath() {
    let e = AppError.validation(["name cannot be empty."], problems: [FieldProblem(field: "group.name", code: "required", message: "name cannot be empty.")])
    XCTAssertEqual(FormErrors(e, fields: ["name": "name", "group.name": "group name"]).byField, ["group.name": "Group name is needed."], "the person's name is not the group's")
  }

  func testWithoutProblemsTheSentencesAreTheGeneralLine() {
    XCTAssertEqual(FormErrors(.validation(["That username is taken."]), fields: account).general, "That username is taken.")
    XCTAssertEqual(FormErrors(.validation(["That username is taken."]), fields: account).byField, [:])
  }

  func testAPenNameCheckSaysTakenInTheAppsWordsAndOtherwiseTheAPIs() {
    XCTAssertEqual(PenNameCheck(name: "Ada Lovelace", available: false, reason: "That pen name is taken.", twoParts: true, reasonCode: "not_unique").refusal,
                   "Ada Lovelace is taken. A pen name once used stays with the person who used it, so choose another.")
    XCTAssertEqual(PenNameCheck(name: "x", available: false, reason: "Too short.", twoParts: true, reasonCode: "length_out_of_range").refusal, "Too short.")
    XCTAssertEqual(PenNameCheck(name: "x", available: false, reason: "Taken.", twoParts: true).refusal, "Taken.", "an API from before #133")
    XCTAssertNil(PenNameCheck(name: "Ada", available: true, reason: nil, twoParts: false).refusal)
  }

  /// Today's API names no field for a username clash, so the sentence is the general line. Once it names the
  /// field (as the #133 proposal described), the unit tests above cover it landing under the box.
  func testJoiningWithATakenUsernameSaysSoInTheAPIsWords() async throws {
    let fake = FakeAPI()
    fake.mode = "e2e"
    fake.accounts = [FakeAPI.Account(id: 3, username: "taken", password: "x")]
    fake.inviteCodes["7Q4M2XKD9HBT"] = ("b1", 1, "unused")
    let app = TestApp { fake.handle($0) }
    do {
      try await app.container.sessions.join(code: "7Q4M2XKD9HBT", username: "taken", password: "Lantern river quiet map 4", email: nil, name: nil)
      XCTFail("expected a refusal")
    } catch {
      let f = FormErrors(AppError.from(error), fields: account)
      XCTAssertEqual(f.byField, [:])
      XCTAssertEqual(f.general, "Username already in use.", "not \"Error joining with the invite code.\"")
    }
  }
}
