@testable import ABCCore
import XCTest

/// Parses fixtures captured from the running API: the same files the Android client is tested against.
final class DirectoryMapperTests: XCTestCase {

  func testPrisonerFullReadMapsWithItsEmbeddedFacility() throws {
    let p = try decodeFixture("prisoner-full.json", as: PrisonerDTO.self).toDomain()
    XCTAssertEqual(p.name, "Alex Johnson")
    XCTAssertEqual(p.birthName, "Alice Johnson")
    XCTAssertEqual(p.interests, ["art", "history"])
    XCTAssertEqual(p.statusNotice, "In transit, location unconfirmed")
    XCTAssertTrue(p.featured)
    XCTAssertEqual(p.releaseDate.map { Calendar.utc.dateComponents([.year, .month, .day], from: $0) }, DateComponents(year: 2030, month: 5, day: 6))
    XCTAssertEqual(p.releaseSummary, "2030")
    XCTAssertEqual(p.facility?.name, "Alpha Prison")
    XCTAssertEqual(p.facility?.addressLines, ["456 Alpha Street"])
    XCTAssertEqual(p.facility?.routing, .directAndScan)
    XCTAssertTrue(p.verification.isStale())
  }

  func testPrisonFullReadMapsRulesRelayGroupsAndPrisoners() throws {
    let f = try decodeFixture("prison-full.json", as: PrisonDTO.self).toDomain()
    XCTAssertEqual(f.name, "Alpha Prison")
    XCTAssertEqual(f.rules.rules.map(\.tag), ["full_name_and_number", "ink_blue_or_black", "no_polaroids"])
    XCTAssertEqual(f.rules.rules[1].label, "Blue or black ink only")
    XCTAssertEqual(f.rules.photoLimit, 3)
    XCTAssertEqual(f.rules.languageNames, ["English", "Spanish"])
    XCTAssertEqual(f.relayGroups.map(\.name), ["Test Chapter", "Relay Test Chapter"])
    XCTAssertEqual(f.prisoners.count, 1)
    XCTAssertEqual(f.scanService, "JPay, $0.35 per page, account required")
  }

  func testChapterFullReadMapsServicesAndRelayPrisons() throws {
    let g = try decodeFixture("chapter-full.json", as: ChapterDTO.self).toDomain()
    XCTAssertEqual(g.name, "Test Chapter")
    XCTAssertEqual(g.location, "Portland, OR, United States")
    XCTAssertEqual(g.services, ["letter_collection", "letter_writing_nights", "domestic_mailing"])
    XCTAssertEqual(g.relayPrisons.count, 2)
    XCTAssertEqual(g.networkRole, "both")
    XCTAssertTrue(g.socialLinks.isEmpty)
  }

  func testListPageParsesWithPagingFields() throws {
    let env = try JSONDecoder().decode(APIEnvelope<[PrisonerDTO]>.self, from: fixtureData("prisoners-page.json"))
    let page: Page<PrisonerDTO> = env.toPage()
    XCTAssertEqual(page.items.count, 3)
    XCTAssertEqual(page.page, 2)
    XCTAssertEqual(page.pageSize, 3)
    XCTAssertEqual(page.total, 40)
    XCTAssertTrue(page.hasMore)
  }

  func testListRowsCarryTheFacilitySummaryAddedInAPIPR79() throws {
    for p in try decodeFixture("prisoners-page.json", as: [PrisonerDTO].self).map({ $0.toDomain() }) {
      let f = try XCTUnwrap(p.facility, "row \(p.id) has no facility summary")
      XCTAssertFalse(f.name.isBlank)
      XCTAssertEqual(p.facilityId, f.id)
      XCTAssertTrue(f.rules.isEmpty) // the summary is light: no rules, no relay groups
    }
  }

  func testAddressLinesComeOutInPostalOrderAndSkipBlanks() {
    let obj: [String: JSONValue] = ["zip": .string("97201"), "street": .string("1 Main St"), "city": .string("Portland"), "note": .string(""), "wing": .string("C"), "floor": .number(2)]
    XCTAssertEqual(addressLines(obj), ["1 Main St", "Portland", "97201", "2", "C"])
    XCTAssertEqual(addressLines(nil), [])
  }

  func testVerificationStalenessIsSixMonths() {
    let now = parseInstant("2026-09-12T00:00:00Z")!
    XCTAssertTrue(Verification(byGroupId: nil, at: nil).isStale(now: now))
    XCTAssertTrue(Verification(byGroupId: 1, at: now.addingTimeInterval(-200 * 86_400)).isStale(now: now))
    XCTAssertFalse(Verification(byGroupId: 1, at: now.addingTimeInterval(-100 * 86_400)).isStale(now: now))
  }

  func testUnknownRoutingAndBadDatesDoNotCrash() throws {
    let dto = try JSONDecoder().decode(PrisonDTO.self, from: Data(#"{"id":1,"prisonName":"X","routing":"carrier_pigeon","verifiedAt":"not a date"}"#.utf8))
    let f = dto.toDomain()
    XCTAssertEqual(f.routing, .unknown)
    XCTAssertNil(f.verification.at)
  }

  func testARuleAnAdminAddedAfterTheAppWasBuiltReadsInTheServersWordsNotWordsMadeFromItsTag() throws {
    // Captured 19 Sep 2026 from API main after PR #93, with `no_glitter_or_stickers` (rule 40) added by an admin.
    let dto = try decodeFixture("prison-rules-pr93.json", as: PrisonDTO.self)
    // The compiled catalog stands for an app whose list is older than the rule: the worst case.
    let rules = dto.toDomain(.compiled).rules.rules
    let rule = try XCTUnwrap(rules.first { $0.tag == "no_glitter_or_stickers" })
    XCTAssertEqual(rule.label, "No glitter or stickers")
    XCTAssertEqual(rule.category, "content")
    XCTAssertEqual(rule.description, "Letters decorated with glitter, stickers or tape are returned to sender.")
    // And it sorts with its category, not at the end with the unknowns.
    let tags = rules.map(\.tag)
    XCTAssertLessThan(try XCTUnwrap(tags.firstIndex(of: "no_glitter_or_stickers")), try XCTUnwrap(tags.firstIndex(of: "mail_read_by_staff")))
  }

  func testAServerFromBeforePR93WhichSendsTagsOnlyStillMaps() throws {
    let dto = try JSONDecoder().decode(PrisonDTO.self, from: Data(#"{"id":1,"prisonName":"Old","mailRules":["no_photos","brand_new_tag"]}"#.utf8))
    let labels = Dictionary(uniqueKeysWithValues: dto.toDomain().rules.rules.map { ($0.tag, $0.label) })
    XCTAssertEqual(labels, ["no_photos": "No pictures", "brand_new_tag": "Brand new tag"])
  }
}

final class LettersMapperTests: XCTestCase {

  func testInboxRowsWithFullTrueCarryThePrisonerAndTheLastMessage() throws {
    let t = try XCTUnwrap(decodeFixture("chats-full.json", as: [ChatDTO].self).first).toDomain()
    XCTAssertFalse(try XCTUnwrap(t.prisoner?.name).isBlank)
    XCTAssertEqual(t.lastMessage?.fromPrisoner, false)
    XCTAssertEqual(t.lastMessage?.status, .queued)
    XCTAssertEqual(t.letters.count, 1)
    XCTAssertTrue(try XCTUnwrap(t.letters.first).canEdit)
    XCTAssertEqual(t.writer?.name, "user1")
  }

  func testChatRowsCarryTheFacilitySummaryAndEmbeddedMessagesNameTheirRelayGroup() throws {
    let t = try XCTUnwrap(decodeFixture("chats-full.json", as: [ChatDTO].self).first).toDomain()
    XCTAssertEqual(t.prisoner?.facility?.name, "Test Prison")
    XCTAssertEqual(try XCTUnwrap(t.letters.first { $0.relayGroupId != nil }).relayGroupName, "Test Chapter")
  }

  func testAPrintedLetterWithHistoryAndRelayGroupMapsAndIsNotEditable() throws {
    let l = try decodeFixture("message-full.json", as: MessageDTO.self).toDomain()
    XCTAssertEqual(l.status, .printed)
    XCTAssertFalse(l.canEdit)
    XCTAssertEqual(l.relayGroupName, "Relay Test Chapter")
    XCTAssertEqual(l.relayGroupId, 2)
    XCTAssertEqual(l.history.map(\.from), [nil, .queued])
    XCTAssertEqual(l.history.map(\.to), [.queued, .printed])
    XCTAssertEqual(l.body, "probe")
    XCTAssertNil(l.relayNote)
  }

  func testAttachmentSizesReadTheWayPeopleSayThem() {
    func label(_ size: Int) -> String { Attachment(id: 1, messageId: 1, name: "a", mimeType: "application/pdf", size: size, nonce: nil).sizeLabel }
    XCTAssertEqual(label(900), "900 B")
    XCTAssertEqual(label(20_480), "20 KB")
    XCTAssertEqual(label(5_767_168), "5.5 MB")
  }
}
