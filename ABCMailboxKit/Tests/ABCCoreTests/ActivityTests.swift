@testable import ABCCore
import XCTest

@MainActor
private final class RecordingNotifier: ActivityNotifier {
  var shown: [(summary: ActivitySummary, unread: Int)] = []
  var cleared = 0
  func show(_ summary: ActivitySummary, unread: Int) { shown.append((summary, unread)) }
  func clear() { cleared += 1 }
}

/// The notification feed (API PR #96): what is new in the account, fetched by the app itself.
@MainActor
final class ActivityTests: XCTestCase {
  private var fake: FakeAPI!
  private var app: TestApp!
  private var notifier: RecordingNotifier!
  private var activity: ActivityRepository { app.container.activity }

  override func setUp() async throws {
    fake = FakeAPI()
    fake.mode = "server"
    fake.accounts = [FakeAPI.Account(id: 4, username: "user1", password: "password1"), FakeAPI.Account(id: 5, username: "user2", password: "password2")]
    let fake = fake!
    app = TestApp { fake.handle($0) }
    notifier = RecordingNotifier()
    app.container.activity.notifier = notifier
    try await app.container.sessions.login(username: "user1", password: "password1")
  }

  func testEveryEventTheAPISendsHasASentenceThatNamesNobodyAndAnUnknownOneStillGetsAWord() {
    XCTAssertEqual(Activity.kind(event: "letter.reply", status: nil), .reply)
    XCTAssertEqual(Activity.kind(event: "letter.status", status: "printed"), .printed)
    XCTAssertEqual(Activity.kind(event: "letter.status", status: "mailed"), .mailed)
    XCTAssertEqual(Activity.kind(event: "letter.status", status: "shredded"), .other)
    XCTAssertEqual(Activity.kind(event: "letter.queued", status: nil), .queuedForGroup)
    XCTAssertEqual(Activity.kind(event: "submission.decided", status: "approved"), .changeApproved)
    XCTAssertEqual(Activity.kind(event: "submission.decided", status: "rejected"), .changeRejected)
    XCTAssertEqual(Activity.kind(event: "something.new", status: nil), .other)
    XCTAssertEqual(Activity(id: 1, kind: .other, chatId: nil, messageId: nil).sentence, "There is something new in your account.")
  }

  func testASyncFetchesWhatIsNewCountsTheUnreadAndAnnouncesOnlyWhenAsked() async throws {
    fake.tell(4, "letter.reply", chat: 12, message: 91)
    fake.tell(4, "letter.status", chat: 12, message: 88, detail: ["status": "mailed"])
    let fresh = await activity.sync()
    XCTAssertEqual(fresh.map(\.kind), [.mailed, .reply]); XCTAssertEqual(fresh.map(\.chatId), [12, 12])
    XCTAssertEqual(activity.unread, 2)
    XCTAssertTrue(notifier.shown.isEmpty, "an open app says it in its own way")

    // Nothing new since: nothing is said twice, and the badge still tells the truth.
    let again = await activity.sync(announce: true)
    XCTAssertEqual(again, []); XCTAssertEqual(activity.unread, 2); XCTAssertTrue(notifier.shown.isEmpty)
    XCTAssertEqual(app.requests(to: "/auth/notifications").last?.query, ["since": "42", "unread": "true"])

    // With nobody looking, the news is announced.
    fake.tell(4, "letter.status", chat: 12, message: 88, detail: ["status": "printed"])
    _ = await activity.sync(announce: true)
    XCTAssertEqual(notifier.shown.map(\.summary.body), ["One of your letters has been printed."])
    XCTAssertEqual(notifier.shown.first?.unread, 3)
  }

  func testOpeningTheInboxMarksEverythingReadHereAndOnTheServer() async throws {
    fake.tell(4, "letter.reply")
    _ = await activity.sync()
    await activity.markAllRead()
    XCTAssertEqual(activity.unread, 0); XCTAssertEqual(notifier.cleared, 1)
    XCTAssertEqual(try XCTUnwrap(app.requests(to: "/auth/notifications/read").first).bodyText, "{}")
    XCTAssertNotNil(fake.notifications[4]?.first?["readAt"] as? String)
    await activity.markAllRead()
    XCTAssertEqual(app.requests(to: "/auth/notifications/read").count, 1, "with nothing unread there is nothing to tell the server")
  }

  func testTwoPeopleSharingAPhoneEachKeepTheirOwnPlaceAndSigningOutClearsTheBadge() async throws {
    fake.tell(4, "letter.reply")
    fake.tell(5, "letter.status", detail: ["status": "mailed"])
    _ = await activity.sync()
    try await app.container.sessions.logout()
    XCTAssertEqual(activity.unread, 0); XCTAssertEqual(notifier.cleared, 1)
    let signedOut = await activity.sync(announce: true)
    XCTAssertEqual(signedOut, [])

    try await app.container.sessions.login(username: "user2", password: "password2")
    let theirs = await activity.sync()
    XCTAssertEqual(theirs.map(\.kind), [.mailed], "user1's place in user1's feed does not hide user2's news")
    XCTAssertNil(app.requests(to: "/auth/notifications").last?.query["since"])
  }

  func testOfflineTheFeedIsQuietAndTheBadgeKeepsItsLastKnownCount() async throws {
    fake.tell(4, "letter.reply")
    _ = await activity.sync()
    fake.noSignal = true
    let offline = await activity.sync(announce: true)
    XCTAssertEqual(offline, []); XCTAssertEqual(activity.unread, 1); XCTAssertTrue(notifier.shown.isEmpty)
  }

  func testSeveralEntriesBecomeOneAnnouncementThatOpensTheConversationOnlyWhenTheyShareOne() throws {
    func entry(_ id: Int, _ kind: Activity.Kind, chat: Int?) -> Activity { Activity(id: id, kind: kind, chatId: chat, messageId: nil) }
    XCTAssertNil(ActivitySummary([]))

    let one = try XCTUnwrap(ActivitySummary([entry(1, .reply, chat: 12)]))
    XCTAssertEqual(one.title, "ABC Mailbox"); XCTAssertEqual(one.body, "A reply to one of your letters has arrived."); XCTAssertEqual(one.chatId, 12)

    let sameThread = try XCTUnwrap(ActivitySummary([entry(3, .mailed, chat: 12), entry(2, .printed, chat: 12), entry(1, .mailed, chat: 12)]))
    XCTAssertEqual(sameThread.title, "3 updates about your letters")
    XCTAssertEqual(sameThread.body, "One of your letters is in the post. One of your letters has been printed.", "each kind of news once")
    XCTAssertEqual(sameThread.chatId, 12)

    let many = try XCTUnwrap(ActivitySummary([entry(5, .reply, chat: 12), entry(4, .mailed, chat: 13), entry(3, .printed, chat: 14), entry(2, .queuedForGroup, chat: nil), entry(1, .changeApproved, chat: nil)]))
    XCTAssertNil(many.chatId, "news about several conversations opens the Inbox")
    XCTAssertTrue(many.body.hasSuffix("And 2 more."))
    for text in [one.body, sameThread.body, many.body] { XCTAssertFalse(text.contains("Jane")) }
  }
}
