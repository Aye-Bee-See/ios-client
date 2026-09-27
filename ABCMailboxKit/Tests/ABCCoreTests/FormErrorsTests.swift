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

  /// The group forms' own cases, with the params the API sends for them (checked against API main).
  func testTheGroupFormsLimitsReadAsTheAppsWords() {
    func one(_ field: String, _ code: String, min: Int? = nil, max: Int? = nil, _ message: String, label: String) -> String? {
      FormErrors(.validation([message], problems: [FieldProblem(field: field, code: code, min: min, max: max, message: message)]), fields: [field: label]).byField[field]
    }
    XCTAssertEqual(one("label", "length_out_of_range", min: 0, max: 80, "label can be at most 80 characters.", label: "label"), "Label can be at most 80 characters.")
    XCTAssertEqual(one("name", "length_out_of_range", min: 3, max: 32, "Name must be between 3 and 32 characters.", label: "name"), "Name must be 3 to 32 characters.")
    XCTAssertEqual(one("lettersSentBefore", "out_of_range", min: 0, max: 100000, "x", label: "number"), "Number must be from 0 to 100000.")
    XCTAssertEqual(one("lettersSentBefore", "out_of_range", max: 0, "lettersSentBefore cannot be negative.", label: "number"), "lettersSentBefore cannot be negative.", "a maximum alone is the API's to word")
    XCTAssertEqual(one("lettersSentBefore", "not_a_number", "lettersSentBefore must be a whole number.", label: "number"), "Number must be a whole number.")
    XCTAssertEqual(one("managerNote", "validation_failed", "managerNote is too long.", label: "note"), "managerNote is too long.")
  }

  func testAPenNameCheckSaysTakenInTheAppsWordsAndOtherwiseTheAPIs() {
    XCTAssertEqual(PenNameCheck(name: "Ada Lovelace", available: false, reason: "That pen name is taken.", twoParts: true, reasonCode: "not_unique").refusal,
                   "Ada Lovelace is taken. A pen name once used stays with the person who used it, so choose another.")
    XCTAssertEqual(PenNameCheck(name: "x", available: false, reason: "Too short.", twoParts: true, reasonCode: "length_out_of_range").refusal, "Too short.")
    XCTAssertEqual(PenNameCheck(name: "x", available: false, reason: "Taken.", twoParts: true).refusal, "Taken.", "an API from before #133")
    XCTAssertNil(PenNameCheck(name: "Ada", available: true, reason: nil, twoParts: false).refusal)
  }

  /// Since API #142 a username clash names its field, so it lands under the username box.
  func testJoiningWithATakenUsernameComesBackUnderTheUsernameField() async throws {
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
      XCTAssertEqual(f.byField, ["username": "That username is already taken. Choose another."])
      XCTAssertEqual(f.general, "Check the fields marked in red.")
    }
  }
}
