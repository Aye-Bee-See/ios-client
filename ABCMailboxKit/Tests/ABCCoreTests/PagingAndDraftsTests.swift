@testable import ABCCore
import XCTest

private struct Row: Identifiable, Equatable, Sendable { let id: Int }

@MainActor
final class PagedLoaderTests: XCTestCase {
  /// 45 rows in pages of 20, like the API: 1-based pages, `hasMore` from the total.
  private func pages(_ calls: CallLog, failOn: Int? = nil) -> PagedLoader<Row>.Fetch {
    { page, size in
      calls.pages.append(page)
      if page == failOn, calls.failuresLeft > 0 { calls.failuresLeft -= 1; throw AppError.network }
      let start = (page - 1) * size
      return Page(items: (start..<min(start + size, 45)).map { Row(id: $0) }, total: 45, page: page, pageSize: size)
    }
  }
  private final class CallLog { var pages: [Int] = []; var failuresLeft = 1 }

  func testLoadsPageByPageAsRowsAppearAndStopsAtTheEnd() async {
    let calls = CallLog()
    let loader = PagedLoader<Row>(fetch: pages(calls))
    XCTAssertFalse(loader.isEmpty, "nothing has been asked yet")
    await loader.refresh()
    XCTAssertEqual(loader.items.count, 20)
    await loader.loadMoreIfNeeded(current: Row(id: 3)) // far from the end: nothing happens
    XCTAssertEqual(calls.pages, [1])
    await loader.loadMoreIfNeeded(current: Row(id: 17))
    await loader.loadMoreIfNeeded(current: Row(id: 39))
    XCTAssertEqual(loader.items.map(\.id), Array(0..<45))
    await loader.loadMoreIfNeeded(current: Row(id: 44))
    XCTAssertEqual(calls.pages, [1, 2, 3], "the last page says there is no more")
    XCTAssertEqual(loader.phase, .idle)
  }

  func testAFailedFirstLoadShowsTheErrorAndAFailedLaterPageCanBeRetried() async {
    let first = CallLog()
    let loader = PagedLoader<Row>(fetch: pages(first, failOn: 1))
    await loader.refresh()
    XCTAssertEqual(loader.phase, .failedFirst(.network))
    await loader.refresh()
    XCTAssertEqual(loader.items.count, 20)

    let later = CallLog()
    let second = PagedLoader<Row>(fetch: pages(later, failOn: 2))
    await second.refresh()
    await second.loadMore()
    XCTAssertEqual(second.phase, .failedMore(.network)); XCTAssertEqual(second.items.count, 20)
    await second.loadMore()
    XCTAssertEqual(second.items.count, 40); XCTAssertEqual(second.phase, .idle)
  }

  func testARefreshKeepsRowsOnScreenAndAResetDropsThem() async {
    let calls = CallLog()
    let loader = PagedLoader<Row>(fetch: pages(calls))
    await loader.refresh()
    await loader.loadMore()
    await loader.refresh()
    XCTAssertEqual(loader.items.count, 20, "back to the first page")
    await loader.reset { _, _ in Page(items: [], total: 0, page: 1, pageSize: 20) }
    XCTAssertTrue(loader.isEmpty)
  }
}

final class DraftsTests: XCTestCase {
  private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("abc-drafts-\(UUID().uuidString)")

  func testADraftRoundTripsPerAccountAndPrisonerAndIsCiphertextOnDisk() throws {
    let secrets = InMemorySecretStore()
    let drafts = DraftsRepository(cipher: SecretCipher(store: secrets), directory: directory)
    let draft = Draft(body: "Dear Jane, this must not be readable on disk.", note: "two pages", relayChapter: 2)
    drafts.save(userId: 4, prisonerId: 3, draft: draft)

    XCTAssertEqual(drafts.load(userId: 4, prisonerId: 3)?.body, draft.body)
    XCTAssertEqual(drafts.load(userId: 4, prisonerId: 3)?.relayChapter, 2)
    XCTAssertEqual(drafts.load(userId: 4, prisonerId: 3)?.paper, false)
    drafts.save(userId: 4, prisonerId: 3, draft: Draft(body: "", note: nil, relayChapter: 2, paper: true))
    XCTAssertEqual(drafts.load(userId: 4, prisonerId: 3)?.paper, true, "the switch is part of the draft (API PR #118)")
    // A draft saved by a version from before the switch has no `paper` key and reads as an ordinary letter.
    let older = try JSONDecoder().decode(Draft.self, from: Data(#"{"body":"Dear Jane","note":null,"relayChapter":null,"updatedAt":0}"#.utf8))
    XCTAssertFalse(older.paper); XCTAssertEqual(older.body, "Dear Jane")
    XCTAssertNil(drafts.load(userId: 5, prisonerId: 3), "another account on the same phone never sees it")
    XCTAssertNil(drafts.load(userId: 4, prisonerId: 9))

    let onDisk = try Data(contentsOf: directory.appendingPathComponent("4_3.draft"))
    XCTAssertNil(String(decoding: onDisk, as: UTF8.self).range(of: "Dear Jane"))

    // The key is gone (the app was reinstalled): the draft is simply lost, not a crash.
    let orphaned = DraftsRepository(cipher: SecretCipher(store: InMemorySecretStore()), directory: directory)
    XCTAssertNil(orphaned.load(userId: 4, prisonerId: 3))

    drafts.delete(userId: 4, prisonerId: 3)
    XCTAssertNil(drafts.load(userId: 4, prisonerId: 3))
  }
}
