@testable import ABCCore
import XCTest

final class ClaimTokenTests: XCTestCase {
  private let good = "DJ69G5K7XBMYFWW4P4PYTJ8C"

  func testEntryIsForgivingAboutCaseDashesAndSpaces() {
    XCTAssertEqual(ClaimToken.normalise("dj69-g5k7 xbmy-fww4-p4py-tj8c "), good)
    XCTAssertTrue(ClaimToken.isWellFormed("dj69-g5k7-xbmy-fww4-p4py-tj8c"))
    XCTAssertEqual(ClaimToken.pretty(good), "DJ69-G5K7-XBMY-FWW4-P4PY-TJ8C")
  }

  func testProblemsAreExplainedBeforeARequestIsSpent() {
    XCTAssertNil(ClaimToken.problem(good))
    XCTAssertEqual(ClaimToken.problem("  "), "Enter the token your group gave you.")
    XCTAssertEqual(ClaimToken.problem(String(good.dropLast())), "That is 23 characters; a token has 24.")
    XCTAssertEqual(ClaimToken.problem(good + "A"), "That is 25 characters; a token has only 24.")
    XCTAssertTrue(ClaimToken.problem("O" + good.dropFirst())!.contains("never contain the character O"))
    XCTAssertFalse(ClaimToken.isWellFormed(good.prefix(3) + "L" + good.dropFirst(4)))
  }

  func testAClaimLinkYieldsItsTokenAndOtherLinksAreIgnored() {
    XCTAssertEqual(ClaimToken.link(URL(string: "abcmailbox://claim?token=\(good)")!)?.token, good)
    XCTAssertEqual(ClaimToken.link(URL(string: "abcmailbox://claim")!), ClaimToken.Link(token: nil))
    XCTAssertNil(ClaimToken.link(URL(string: "abcmailbox://inbox")!))
    XCTAssertNil(ClaimToken.link(URL(string: "https://example.org/claim?token=\(good)")!))
  }
}

final class MailRulesTests: XCTestCase {
  private let catalog = MailRuleCatalog.compiled
  private func rules(_ tags: String..., pages: Int? = nil, photos: Int? = nil, languages: [String] = []) -> MailRules {
    MailRules(rules: catalog.resolveAll(tags), pageLimit: pages, photoLimit: photos, languages: languages)
  }

  func testTheCompiledVocabularyCoversEveryTagTheServerPublishes() throws {
    // Fixture captured from GET /prison/mail-rules. If this fails, regenerate CompiledMailRules.swift.
    let live: MailRuleVocabularyDTO = try decodeFixture("mail-rules.json")
    let missing = Set((live.rules ?? []).map(\.tag)).subtracting(CompiledMailRules.rules.map(\.tag))
    XCTAssertEqual(missing, [], "tags missing from the compiled vocabulary")
    XCTAssertEqual(live.categories, CompiledMailRules.categories)
  }

  func testAnUnknownTagDisplaysAsReadableTextAndBreaksNothing() {
    XCTAssertEqual(catalog.resolve("no_glitter_pens").label, "No glitter pens")
    let all = catalog.resolveAll(["no_glitter_pens", "no_photos", "return_address_required", "no_photos"])
    XCTAssertEqual(all.map(\.tag), ["return_address_required", "no_photos", "no_glitter_pens"]) // vocabulary order, duplicates dropped, unknown last
  }

  func testLinesShowTagsThenTheValuedRules() {
    XCTAssertEqual(
      rules("no_photos", "return_address_required", pages: 4, photos: 1, languages: ["en", "es"]).lines(),
      ["Return address required", "No pictures", "At most 4 pages per letter", "At most 1 photo per letter", "Accepted languages: English, Spanish"]
    )
    XCTAssertTrue(MailRules().isEmpty)
    XCTAssertFalse(rules(pages: 2).isEmpty)
  }

  func testPageLimitWarnsOnlyWhenTheEstimateExceedsIt() throws {
    let r = rules(pages: 2)
    XCTAssertTrue(composeAdvice(rules: r, estimatedPages: 2, imageAttachments: 0).isEmpty)
    let advice = composeAdvice(rules: r, estimatedPages: 3, imageAttachments: 0)
    XCTAssertEqual(advice.count, 1)
    let over = try XCTUnwrap(advice.first)
    XCTAssertTrue(over.warning); XCTAssertTrue(over.text.contains("about 3 pages")); XCTAssertTrue(over.text.contains("at most 2"))
  }

  func testLanguagesPicturesPhotoLimitsAndHandwritingProduceAdvice() throws {
    let a = composeAdvice(rules: rules("no_photos", "handwritten_only", languages: ["es"]), estimatedPages: 1, imageAttachments: 0)
    XCTAssertTrue(a.contains { $0.text.contains("Spanish") && !$0.warning })
    XCTAssertTrue(a.contains { $0.text.contains("refuses pictures") })
    XCTAssertTrue(a.contains { $0.text.contains("handwritten") && $0.warning })
    let photos = composeAdvice(rules: rules(photos: 2), estimatedPages: 1, imageAttachments: 3)
    XCTAssertEqual(photos.count, 1)
    XCTAssertTrue(try XCTUnwrap(photos.first).warning); XCTAssertTrue(try XCTUnwrap(photos.first).text.contains("at most 2 photos"))
    XCTAssertTrue(composeAdvice(rules: MailRules(), estimatedPages: 10, imageAttachments: 5).isEmpty)
  }

  func testOnlyNoPhotosTurnsImageAttachmentsOff() {
    XCTAssertTrue(rules("no_photos").forbidsPhotos)
    XCTAssertFalse(rules("no_polaroids", "no_explicit_photos").forbidsPhotos)
  }
}

/// The client-side mirror of the API's relay rules (README, "Relay group").
final class RelayResolutionTests: XCTestCase {
  private func group(_ id: Int, status: String? = "active") -> SupportGroup { SupportGroup(id: id, name: "Group \(id)", networkRole: "relay", accountStatus: status) }
  private func facility(_ routing: Routing, _ groups: [SupportGroup]) -> Facility {
    Facility(id: 1, name: "F", addressLines: [], country: nil, routing: routing, scanService: nil, notes: nil, verification: Verification(byGroupId: nil, at: nil), prisoners: [], rules: MailRules(), relayGroups: groups)
  }

  func testOneRelayGroupIsAutomatic() { XCTAssertEqual(resolveRelay(facility(.direct, [group(7)])), .automatic(group(7))) }

  func testNoRelayGroupAndDirectMailMeansDirect() {
    XCTAssertEqual(resolveRelay(facility(.direct, [])), .direct)
    XCTAssertEqual(resolveRelay(nil), .direct)
  }

  func testNoRelayGroupOnARelayOnlyFacilityIsBlocked() {
    guard case .blocked = resolveRelay(facility(.relayOnly, [])) else { return XCTFail("expected blocked") }
  }

  func testSeveralGroupsNeedAChoiceRequiredOnlyForRelayOnly() {
    XCTAssertEqual(resolveRelay(facility(.directAndScan, [group(1), group(2)])), .choose(options: [group(1), group(2)], required: false))
    XCTAssertEqual(resolveRelay(facility(.relayOnly, [group(1), group(2)])), .choose(options: [group(1), group(2)], required: true))
  }

  func testSuspendedGroupsAreNotOffered() { XCTAssertEqual(resolveRelay(facility(.direct, [group(1, status: "suspended"), group(2)])), .automatic(group(2))) }

  func testPageEstimate() {
    XCTAssertEqual(estimatePages(characters: 0), 1)
    XCTAssertEqual(estimatePages(characters: 3000), 1)
    XCTAssertEqual(estimatePages(characters: 3001), 2)
    XCTAssertEqual(estimatePages(characters: 10_000), 4)
  }
}

final class GroupRulesTests: XCTestCase {
  func testAGroupMayChangeLettersOnlyForWritersItWritesFor() {
    let managed = ThreadWriter(id: 4, name: "Alex", managedByGroupId: 1, anonymousForGroupId: nil)
    let anonymous = ThreadWriter(id: 5, name: "anon", managedByGroupId: nil, anonymousForGroupId: 1)
    let independent = ThreadWriter(id: 6, name: "Sam", managedByGroupId: nil, anonymousForGroupId: nil)
    XCTAssertTrue(mayChangeLetters(viewerIsStaff: false, viewerGroupId: nil, writer: independent)) // a writer in their own thread
    XCTAssertTrue(mayChangeLetters(viewerIsStaff: true, viewerGroupId: 1, writer: managed))
    XCTAssertTrue(mayChangeLetters(viewerIsStaff: true, viewerGroupId: 1, writer: anonymous))
    XCTAssertFalse(mayChangeLetters(viewerIsStaff: true, viewerGroupId: 1, writer: independent))
    XCTAssertFalse(mayChangeLetters(viewerIsStaff: true, viewerGroupId: 2, writer: managed))
    XCTAssertFalse(mayChangeLetters(viewerIsStaff: true, viewerGroupId: nil, writer: managed))
    XCTAssertEqual(anonymous.label, "Anonymous writer")
  }
}

final class DevServerTests: XCTestCase {
  func testNormaliseAcceptsTheFormsAPersonTypes() {
    XCTAssertEqual(DevServerRepository.normalise("192.168.1.20"), "http://192.168.1.20:3000/")
    XCTAssertEqual(DevServerRepository.normalise(" 192.168.1.20:3000 "), "http://192.168.1.20:3000/")
    XCTAssertEqual(DevServerRepository.normalise("http://192.168.1.20:8080/some/path?x=1"), "http://192.168.1.20:8080/")
    XCTAssertEqual(DevServerRepository.normalise("https://api.abcmailbox.net"), "https://api.abcmailbox.net/")
    XCTAssertEqual(DevServerRepository.normalise("mymac.local"), "http://mymac.local:3000/")
    XCTAssertNil(DevServerRepository.normalise(""))
    XCTAssertNil(DevServerRepository.normalise("not a url at all"))
  }
}
