# ABC Mailbox for iOS

The iPhone and iPad client for Aye Bee See, a correspondence network for political prisoners. Writers find a prisoner, read the facility's mail rules, and write; a support group prints and mails the letter and records the reply.

It does what the Android client (`../Android`) did as of its phase 10 (19 September 2026), push aside, screen for screen, and speaks the same API and the same end-to-end encryption. What Android has since gained and this app has not is listed under "Behind Android" below. The Android documents remain the map: `../Android/docs/PLAN.md` for what is built and why, `../android-client-brief.md` for the API. This directory adds only what is particular to iOS:

- `docs/DECISIONS.md`: choices that are not obvious from the code (crypto library, Keychain, project layout), and every place this app deliberately differs from Android.

## Layout

| Path | What |
| --- | --- |
| `ABCMailbox.xcodeproj` | The Xcode project: one app target, iOS 17+, iPhone and iPad. Bundle id `me.paxana.abcmailbox`. |
| `ABCMailbox/` | The app target: SwiftUI only. `App/` (entry point, navigation), `Common/` (theme, shared views), then one folder per area: `Directory/`, `Auth/`, `Letters/`, `GroupWork/`, `Account/`. Xcode picks up files added to this folder by itself. |
| `ABCMailboxKit/` | A local Swift package holding everything that is not UI, so it builds and tests on the Mac with no simulator. |
| `ABCMailboxKit/Sources/ABCCrypto` | The only code that talks to libsodium (`Sodium.swift`). Mirrors Android's `:crypto` module, file for file. |
| `ABCMailboxKit/Sources/ABCCore` | API client, session and keys, repositories, domain models, the offline directory. Mirrors Android's `data/` and `domain/`. |
| `Config/Info.plist` | The few Info.plist keys Xcode cannot generate: the `abcmailbox://` link scheme, the local-network exception, the API address. |
| `tools/` | `verify-swift-fixture.mjs` (libsodium.js opens what Swift encrypted), `typecheck-app.sh`, `make-app-icon.swift`. |

## Build and test

Requires Xcode 26 (Swift 6 toolchain; the code is in Swift 5 language mode). The first build downloads one dependency, [swift-sodium](https://github.com/jedisct1/swift-sodium), for its prebuilt libsodium.

```bash
cd ABCMailboxKit && swift test
```

That is the whole test suite: about 150 tests in a few seconds, on the Mac. It includes the crypto fixtures the Android client is tested against (made by the API's own `services/crypto.js` and by libsodium.js), and whole account, letter and group flows run against a stub server with real Argon2id and real sealed boxes.

To run the app, open `ABCMailbox.xcodeproj`, choose the `ABCMailbox` scheme and a simulator, and run. To sign and run on a phone, set your team under Signing & Capabilities.

Three more checks, each opt-in:

```bash
# The other direction of the crypto proof: libsodium.js opens what Swift produced.
# (`swift test` writes the fixture; `npm install` once in ../Android/tools.)
node tools/verify-swift-fixture.mjs

# The core layer against a running API. Read-only: it signs in and reads, never sends or changes anything.
cd ABCMailboxKit && ABC_LIVE_SERVER=http://localhost:3000 ABC_LIVE_E2E=http://localhost:3100 swift test --filter LiveServer

# The one live test that changes anything: it deletes the seeded account user3, wrong password first.
# Only for an API you started to throw away; it refuses ports 3000 and 3100.
cd ABCMailboxKit && ABC_LIVE_THROWAWAY=http://localhost:3199 swift test --filter testThrowawayServer

# Returned mail, a release and a move, played by a writer and a group member. It edits the directory and moves
# letters, so it too is only for a throwaway API (PR #106 or later, ADMIN_PASSWORD=abcpassword), after
# `python3 ../Android/tools/dev-seed.py http://localhost:3199` has added member1 and the relay links.
cd ABCMailboxKit && ABC_LIVE_THROWAWAY=http://localhost:3199 swift test --filter testThrowawayServerReturnedMovedAndFreed

# Letter nights and a group's numbers (API pull requests #111 and #112), same throwaway set-up as above.
cd ABCMailboxKit && ABC_LIVE_THROWAWAY=http://localhost:3199 swift test --filter testThrowawayServerLetterNightsAndNumbers

# Every response captured by Android's tools/capture-contract.py still decodes with this app's types.
cd ABCMailboxKit && ABC_CONTRACT_DIR=/tmp/contract swift test --filter ContractCheck
```

`tools/typecheck-app.sh` compiles the app target against the iOS SDK without Xcode's build system. It exists for machines where Xcode's iOS platform component is not installed (every `xcodebuild` destination is then refused) and for a quick check in CI.

## Run against a local API

1. Start the API and seed it exactly as `../Android/README.md` describes (`DB_RESET=true npm start`, then `python3 ../Android/tools/dev-seed.py`).
2. Run the app in a simulator. Debug builds talk to `http://localhost:3000/`: the simulator shares the Mac's network, so there is no `10.0.2.2` to remember.
3. Sign in as `user1` / `password1` for a writer who already has a thread, or `member1` / `password1` for a group member.

One build works against both API modes: the app asks `GET /health` which letter contract the server speaks (`server` or `e2e`) and encrypts on the device when it must.

To open the claim screen by link: `xcrun simctl openurl booted "abcmailbox://claim?token=XXXXXXXXXXXXXXXXXXXXXXXX"`.

## Run on a physical phone

Debug builds have the same hidden server setting as Android: on the Account tab, tap the "Build … mode" line five times. Enter the address of the machine running the API (for example `192.168.1.20`; port 3000 is assumed) and tap "Save and check"; the app calls `/health` there and reports the result. Saving signs you out, because a token is only valid for the server that issued it, and downloads that server's directory for offline use.

Both devices must be on the same Wi-Fi, the API must listen on all interfaces (it does), and the Mac's firewall must allow incoming connections for node. The first request makes iOS ask for permission to find devices on the local network; say yes. Plain `http` is allowed to local addresses only (an IP, `localhost`, `*.local`); anything else, including the release API, must be `https`.

## Writing without a connection

Pressing Send with no route to the server puts the letter in an outbox, encrypted under a key in the Keychain as drafts are. Every letter, and every file with it, carries an `Idempotency-Key` made once and repeated on each retry (API pull request #97), so a letter whose first attempt did arrive unheard comes back as itself rather than being mailed twice. In end-to-end mode the letter is sealed when it is sent, not when it is written, because sealing needs the relay group's current public key. Waiting letters show above the Inbox, with a count on the tab, and can be edited, deleted, or tried at once; a refused one keeps the server's reason.

When they go out is where iOS is weaker than Android. While the app is open it watches the network and sends the moment there is one; it also sends at launch, on coming to the front, and after sign-in. With the app closed, it asks iOS for a background task that needs a network, and iOS runs that when it chooses, often hours later and never for an app the person has swiped away. The Inbox says so in plain words.

## Keys appear as people sign in

The move to end-to-end encryption does not wait for anyone to be reached (API pull request #95). After every sign-in, in either mode and without asking, the app makes the account's keys if it has none (the recovery code is shown once and cannot be skipped), and re-wraps them on a password change. For a group member it then makes the group's key if the group has none, gives keys to unclaimed writers who have none (never to the group's shared anonymous account), and, after the switch, shares replies with writers who had no keys when the reply was recorded. One step is left to a person: handing the group key to a member who lacks it is offered on the Inbox with one confirmation (`docs/DECISIONS.md` says why). A letter nobody has sealed to its writer yet says so, rather than showing as empty or locked.

This is the full list from the API's migration guide. Android, as of `cbf93c3`, does only the last two items, so here iOS is ahead of it.

## What is new in the account

The notification feed (`GET /auth/notifications`, API pull request #96) says that a reply arrived, that a letter was printed or mailed, that a letter is waiting for the group, or that a proposed change was decided. Entries carry ids and states, never content, and what they *say* is worded on the phone and names nobody ("A reply to one of your letters has arrived."), because it ends up on a lock screen. The Inbox tab's badge counts unread news plus letters waiting in the outbox; opening the Inbox marks the news read, on this phone and the person's others. With the app open the news is a toast; otherwise it is one notification, which opens the conversation when all its news is about one, and the Inbox when not.

The app fetches the feed when it opens and when iOS grants a background refresh (asked for every six hours; iOS decides). Permission for notifications is asked only when the person taps "Allow notifications" on the Account tab or queues a letter offline, never at launch.

## Deleting an account

Account tab, last item: "Delete my account…" (API pull request #104). The server deletes the person with everything they wrote and received, whatever its status, and it cannot be undone, so the screen says in words what will go and what will not (a letter already in the mail is not recalled; what a group member did for their group stays, without their name) before it asks for anything. Then four things stand between a person and a mistake: typing their username, their password (which the phone proves by signing in with it before it asks for anything, and the server checks again, so a borrowed phone is not enough even against an API build older than the feature), ticking "I understand this cannot be undone", and a last confirmation that names the consequence again. A group member who is the only holder of their group's key is told so up front and sent to the Group key screen, instead of meeting the server's refusal at the end. Nothing is removed from the phone unless the server says the account is gone; when it has, the phone keeps nothing either: session, keys, drafts, unsent letters, and the account's place in its notification feed.

Not built: a group deleting one of its unclaimed managed writers, which the same endpoint allows without a password.

## Letters that come back, and people who are moved or freed

API pull requests #105 and #106.

**Returned mail.** A group member opens a mailed letter and taps "It came back…": one of the API's six reasons, and optionally what the envelope said (200 characters, counted and refused on the phone before the server has to). The sheet says plainly that the writer reads the note and that it is never encrypted, so nothing about the letter belongs in it. After a return that doubts the address (`transferred`, `released`, `bad_address`) the member is reminded that the directory needs correcting if the group knows where the person is now. The queue has a Returned filter. The writer's feed says only "One of your letters came back in the mail." (the reason is inside the app, not on a lock screen); the conversation shows the reason in words, the group's note, and "Send it again". The server keeps no copy to send again (in end-to-end mode it could not read one), so the compose screen opens with the returned letter's text, note and files, downloaded and staged again, and the new letter names the old one (`resendOf`). The relay group is not copied: the letter is routed afresh. Under the reason, until the letter has been sent again, is advice for that reason (six of them, in the Android app's words): what to check or change first, and what sending again will do. A returned letter can be sent again once; after that the card says when, and how the new letter is doing.

**Moved and freed.** Two new feed events have words ("Someone you write to was moved to another facility.", "Someone you write to has been released.", each with how many letters are now waiting for the writer). A held letter stays queued on the server, but its chip says "On hold" and not "Queued", and it says why, in the writer's conversation and in the group's queue (a Held filter, `held=true`):

- `choose_relay`: "Choose who mails it" asks the directory where the person is now and offers that facility's active relay groups; the choice is sent as `{id, relayChapter}` and nothing else.
- `reseal_needed` (end-to-end mode): "Send it again" opens the compose screen with the letter; sending seals it to the group that mails to the new facility, and only then deletes the held copy. This one does not fall back to the outbox when offline, because the held copy is still safely on the server.
- `prisoner_free`: the writer is told they can delete it or leave it. The group member sees "Print it anyway…" instead of "Mark as printed", and a confirmation before `release: true` is sent. If the hold appeared after the screen was loaded, the server's `LetterHeldError` reloads the letter and says so instead of printing.

Not built, because this app has no screens that edit the directory: the `addressInDoubt` worklist and the `mail` report that `PUT /prisoner/prisoner` returns. Those belong to the dashboard.

## Letter nights, a group's numbers, and the API's brief of 21 September

The API side wrote a brief for both mobile clients (`../mobile-agents-brief-2026-09-21.md`). Its "check first" list was gone through item by item. Three things were missing here, the same three Android found:

- **One feed entry for several letters** (`message: null`, `detail.count`) now says how many: "3 of your letters have been printed."
- **A group that is pending or suspended** is no longer offered, or at sign-in silently given, a key set-up that can only be refused. The keyring tells it apart from "no key yet" by asking a group key endpoint, which answers 403 for such a group, and the Inbox says "Your group is not active yet" in either mode.
- **Handing the group key over names its version** (`keyVersion`). A `409 KeyVersionError` means the group rotated while this phone was sealing: the new key is fetched and the person is asked to try again; the stale key is not handed on.

The rest held: unknown statuses and events are neutral, `email` is not read from a thread's writer, only ids and single values are sent, a group that only mails a thread is not offered Edit or Delete, credentials travel in the body, no response is cached, and custody keys are only made by a member whose group key is open.

**Letter nights (API pull request #111).** The print queue is one request (`full=true`): each row brings the prisoner, the facility, its address and rules, so the per-letter lookups are gone (kept as the fallback for an older API, which sends rows without them). With more than one letter in Queued or Printed, "Select several…" turns rows into tick boxes with a bar at the bottom; one `PUT /messaging/status/batch` moves them, all or none. A held letter cannot be ticked: it is a decision of its own. A refusal says "Nothing was changed." and the server's sentence, which names the letter, and the ticks stay so that one can be unticked and the rest tried again. More than 200 is refused on the phone rather than split, which would stop being all or none. "Changed by someone else meanwhile" (another volunteer, or a double tap) is not shown as a failure: the list or the letter is loaded again and says how things stand.

**A group's numbers (API pull request #112).** The public group page shows "Letters mailed" and "Usual time from written to mailed" when the server publishes them, and nothing at all otherwise: never "0". Members get "Your group's numbers" on the Account tab: what the public sees (or why nothing yet, and where the group stands), what the site has counted, and the one number a person types, `lettersSentBefore`, sent by itself. Against an API that does not count yet the page says so.

## Behind Android

Android does not have API pull requests #105 and #106 yet (as of its commit `09e4280`); in that respect this app is ahead. As of Android commit `356a743`, not yet in this app:

- **Spanish and Russian** (Android phase 9). Every string here is English, in the Swift source.
- **The push doorbell** (API pull request #96, Android phase 10). iPhones are reached through Firebase, so this needs a Firebase project with this app added to it (`GoogleService-Info.plist`), an APNs key from a paid Apple developer account uploaded there, the Push Notifications capability, and a notification service extension to replace the server's bland alert with wording made on the phone. None of that exists yet on either platform. It will change when the news arrives, not what is shown: a push carries nothing, and the feed below is where the news comes from either way. Registering the device (`POST /auth/device`) and the devices list belong with it.
- An accessibility pass (Android phase 7c). Fields and buttons are labelled for VoiceOver, but nothing has been listened to.

## What was verified, and what was not

As of 20 September 2026.

- **Verified by tests and tools.** All tests pass. Crypto interoperates with the API and libsodium.js in both directions. Against the live development servers: the directory, the offline download, a writer's threads, a group's queue and writers in server mode; and in end-to-end mode, a group member's key (wrapped by the Android app) opened with their password, the group key opened with that, and letters written by other clients decrypted. The app builds in Xcode, Debug and Release, with no warnings, including the asset catalog (icon, accent colour).
- **Seen on screen** (iPhone 17 simulator, iOS 26.5, against the local API in server mode, signed out): the Directory home page with featured prisoners, the prisoners list with its filters and with more rows loading as it scrolls, a prisoner's profile, the sign-in screen, and the Account tab with the offline directory downloaded on launch and the server's mode detected. That first run found two layout bugs, both fixed: interest tags wrapping onto a line whose height the row had not reserved, so the next row's divider ran through them; and "Est. release" breaking in the middle.
- **Seen since, signed in as a group member:** the print queue.
- **Account deletion, against a real API (20 September 2026).** On a throwaway server with API pull request #104 and its seeded account `user3`: the server refuses a wrong password with 403, the app's own check stops a wrong password before any delete request is sent, the account and its two conversations are still there afterwards, the right password deletes them, and signing in again is refused. The delete screen itself was not driven end to end in the simulator; its model is covered by unit tests.
- **Returned, moved and freed, against a real API (20 September 2026).** On a throwaway server at API pull request #106, server mode, with the writer's and the group member's side of the core layer: a mailed letter recorded as returned with reason and note, the writer's feed and letter showing it, sending it again refused before the return and accepted after, `resent_as` linking the two; a release holding the queued letter, the group's held list, printing refused with `LetterHeldError` and accepted with `release: true`; a move to a relay-only facility with two groups holding a letter as `choose_relay`, the directory offering both groups, the writer's choice lifting the hold and putting the letter in that group's queue. **Seen on screen** (iPhone 17 simulator, signed in as a group member, against a development API at pull request #105): the queue's five filters, a letter taken from queued to printed to mailed, the "It came back" sheet, the return recorded, and the returned letter in the conversation with its reason and the group's note. That look found two bugs, both fixed and under test: the Held filter listed everything on an API older than #106, and the conversation showed no note. **Not verified:** `reseal_needed` against a real end-to-end server (no test plays the phone's send-then-delete either; only the send and delete calls it is built from are tested); the hold notices, "Print it anyway" and "Choose who mails it" on screen (that server had no #106); and "Send it again" on screen (it needs the writer signed in).
- **Letter nights and group numbers, against a real API (21 September 2026).** On a throwaway server at the API's `main` with #111 and #112, freshly seeded (which works again since API pull request #107): queue rows arrive addressed without a prisoner lookup; three letters, one of them already printed, are refused together with "Letter 42: a printed letter cannot move to printed." and nothing moves; two moved together give their writer one feed entry, "2 of your letters have been printed."; a group under twenty publishes nothing, and after `lettersSentBefore` 25 and three mailings publishes "28", on its public page too. The returned, moved and freed test passes on that server as well. **Seen on screen as a writer:** the returned letter with the group's note, the advice for its reason, and "Send it again" opening the compose screen from its text. **Not seen on screen:** "Select several…", the group's numbers page and the inactive-group notice (the simulator was signed in as a writer), and no development server had a pending group.
- **Not yet seen on screen.** The outbox (it needs the API to be unreachable, and the development server was in use); the rest behind sign-in: the writer's inbox, threads, compose and attachments, claim, recovery and the recovery-code screen, password change, and all of the group screens; the facilities and groups lists and pages; anything against the end-to-end server; the saved-copy banner with no connection; the camera and printing; an iPad; dark mode; large text sizes; VoiceOver. The logic behind those screens is tested; their layout is not. Expect more findings of the kind above. The "what to try by hand" lists in `../Android/docs/PLAN.md` apply unchanged.
