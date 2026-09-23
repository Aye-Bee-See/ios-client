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

# Paper letters (API pull request #118) on the same end-to-end throwaway.
cd ABCMailboxKit && ABC_LIVE_THROWAWAY=http://localhost:3199 swift test --filter testThrowawayServerPaperLetters
# Invite codes (API pull request #116) on the same end-to-end throwaway.
cd ABCMailboxKit && ABC_LIVE_THROWAWAY=http://localhost:3199 swift test --filter testThrowawayServerInviteCodes

# Group roles (API pull request #115) on the same end-to-end throwaway, which needs a second group admin, member2,
# created before the flag goes on (under it an admin cannot create one).
cd ABCMailboxKit && ABC_LIVE_THROWAWAY=http://localhost:3199 swift test --filter testThrowawayServerGroupRoles

# The split scheme on an end-to-end API with REQUIRE_SPLIT_AUTH on (API pull request #114): an account from before
# signs in by the fallback and moves to split at a password change; a newcomer claims split, writes and reads a
# sealed letter, signs in again, recovers, and deletes. Throwaway only: seed and run dev-seed.py with the flag OFF
# (under it an admin cannot create member1), then restart with ENCRYPTION_MODE=e2e REQUIRE_SPLIT_AUTH=true.
cd ABCMailboxKit && ABC_LIVE_THROWAWAY=http://localhost:3199 swift test --filter testThrowawayServerEndToEndSplitAuth

# Claim tokens carry the server's date (API pull request #113). Replaces a managed writer's token; throwaway only.
cd ABCMailboxKit && ABC_LIVE_THROWAWAY=http://localhost:3199 swift test --filter testThrowawayServerAClaimTokenSaysHowLongItIsGoodFor

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

## Paper letters

API pull request #118: a letter written by hand and handed to the relay group to mail is logged, so that a reply has a thread to come back to.

*The writer* (and a group admin writing for someone) gets a switch on the letter form, "This letter is on paper". On, no text is needed (a transcription is optional), the page count and the rules' advice go away, and the letter is sent with `paper: true`; in end-to-end mode an empty string is sealed all the same, because that content key is what the photo is encrypted with. The card in the conversation reads "→ On paper", with an "On paper" chip in place of "Printed", says "Written by hand and handed to Test Chapter to mail" when nothing was typed, and offers "Add a photo of the page" until the group mails it, since a paper letter's files may follow the record (`Letter.canAttach`). It cannot be edited or deleted: it is printed from birth. The switch is never offered for a reply (every reply already is on paper) nor on an edit, and the codec never sends the flag on a reply.

*The group* never sees a paper letter under Queued. A queue row carries no files, even with `full=true`, so the photo is on the letter page, which reads the letter by itself. Under Printed its row says "On paper, nothing to print"; the letter page has no "Print the letter" button and a banner saying the writer handed it over already; it goes out with the batch like any printed letter. The feed says "A paper letter is waiting to go out with your group's next batch." (`letter.queued` with `detail.paper`).

Letters queued offline by a version from before the flag still open; the `Idempotency-Key` covers whether a letter is on paper, as the API's fingerprint does.
## Invite codes: how writers join

API pull request #116; public registration is closed, and this app never had a sign-up screen. Sign in offers "I have an invite code" beside "I have a claim token".

*The newcomer.* The code on the slip is typed anyhow (case, dashes, spaces; `O`, `I` and `L` fold to `0`, `1`, `1`, as the server folds them) and checked on the phone before any request, because the check is rate limited. `GET /auth/join` says who is inviting and until when ("Test Chapter is inviting you… good until 26 September"); then a username, a password with the meter, an optional name and email. The keypair is made on the phone and goes with `POST /auth/join`, split, so the password never reaches the server; the account is the person's from the first request (`sponsoredBy` records the chapter; the app reads it and never sends it), the recovery code is shown once, and the sign-in that follows is one derivation. A `400` does not spend the code, so the same code is sent again after a fix. A dead code is worded by its `condition` (`used`, `cancelled`, `expired`, `inactive`); `unknown` is a 404. The QR on a slip opens `https://letters.support/join?code=…`, and the app's own `abcmailbox://join?code=…` does the same; both fill the code in and check it at once. The web link needs an associated-domain entitlement and a file on the site before iOS hands it to the app, which is not set up yet.

*The chapter.* Writers tab, "Print invite codes": a count (1 to 50), a label, and the codes come back once, as slips on the screen (code in fours, the group's name, the QR) and as a PDF made on the phone (four slips to a page, with "use by" the server's date) to print or share. Leaving the screen forgets them, as the API asks. Below, the quota: "2 of 20 unused codes out", each batch with used, unused, cancelled and expired counts, "Cancel unused" per batch and for all, each behind a confirmation that says accounts already made stay. Over the quota, the API's own sentence.

## Group roles

API pull request #115: three kinds of account, and the words the screens now use: *superadmin* (runs the site, holds no key, reads no letters), *group-owner admin* (one per group: hands the key out, takes it back, rotates it, passes the role on) and *group admin* (works the queue, records replies, reads if handed the key); *writer* as before. "Member" and "network admin" are gone from the screens. Built to Android's decisions, so a volunteer who uses both sees one behaviour.

*The key page* says first who the group-owner admin is ("You are…", "Noor is…", or that nobody is yet), then the warning the API asked for, said strongly: every holder of the group key can read every letter the group mails and every reply it records. The owner's row wears a badge; a group admin with keys of their own and none of the group's reads "Noor is waiting for the group key" (`waiting` from `GET /auth/member-keys`). The controls are the owner's alone: Hand key, Stop, and **Make owner**, which asks once more and says the caller stops being the owner. Everyone else sees a list. Make owner is offered only beside a group admin who already holds the key, and `GroupRepository.makeOwner` refuses for one who does not: an owner without the key could hand it to nobody, not even themselves, and only a superadmin could undo that (`docs/DECISIONS.md`; Android's ask 27 to the API). The "not been given the key yet" notice on the Inbox leads to the page, and the waiting notice is shown to the owner only, since nobody else can act on it.

*The feed* words `group.key` (set; handed and withdrawn, which read as "you" when about this account; rotated), `group.owner` ("You are now…" when it is) and `group.waiting`. Any event that touches this account's key or role makes the phone reload the group key, so a copy handed or withdrawn, or the role passed, takes effect without a sign-out.

*Leaving.* A group-owner admin whose group has other group admins is refused by the server. The delete-account page says so before asking for anything, with the way to the key page, and a refusal that arrives anyway is worded by the `condition` the API sends since pull request #117 (`group_owner`, `last_key_holder`), not by matching words in its sentence; one without a code keeps the server's sentence.

*An older API* (no `owner` in the members list) names no owner; there, any holder may hand the key, as before.

Not built: rotation, which this app has never had (the website does it).

## The password never reaches the server

API pull request #114, the split scheme; decided on 22 September 2026 that every new account is split and that `REQUIRE_SPLIT_AUTH` goes on before the first letter night, on an end-to-end server. The phone runs the slow derivation once (Argon2id, with the account's salt and recipe from `GET /auth/login-params`) and takes two unrelated keys from the result with `crypto_kdf_derive_from_key`: the *wrap key* opens the private key and never leaves the phone; the *auth key* goes to the server as the password, 44 characters of base64. `SplitAuth` in `ABCCrypto` matches the API's vector byte for byte (`SplitAuthTests`). The private key is wrapped under the wrap key with the same salt and recipe, so one derivation opens both the server's door and the key.

*Where it goes.* Sign-in is the handshake, the derivation, then one request (`SessionRepository.signIn`). Claim, password change and recovery send `authScheme: "split"`, the auth key, and the key fields re-wrapped under the wrap key; deleting an account proves the auth key. A split account with no keys yet (made by an admin) gets them at first sign-in, wrapped under that sign-in's wrap key with the same salt. The phone remembers which usernames it has signed in to as split (`SchemeMemory`, in UserDefaults, never cleared by signing out or by deleting an account) and refuses to sign in to one of them as plain whatever the server says, with a sentence that says why. An older API (404 on the handshake) means plain everywhere; a handshake that answers with anything other than a complete `split` or an explicit `plain` is refused, so a malformed or tampered answer cannot be a way to be sent the password.

*The fallback.* With the flag on, the handshake answers "split" for every name so as to say nothing about any of them, and an account from before the scheme can only sign in with the password itself. So a refused auth key is followed, once, by the password, but only for a name this phone has never known as split. The same for unlocking on a phone without the key. The cost, which Android's plan lists as ask 23: a mistyped password for such an account, on a phone that does not know it, reaches the server in plain.

*Rules.* At least 10 characters, on the phone (`PasswordRules`), and a strength meter under each new-password field: four bars and a word that says it is a rough guess. Four or more words with spaces score as a passphrase. The server applies no rule to a split password beyond its shape.

## Claim tokens say their date, never a number of days

API pull request #113: a claim token lasts two weeks by default, and the server's operator can change that (`CLAIM_TOKEN_DAYS`). The app said "72 hours" in three places; it now says no number anywhere. The volunteer's hand-off screen shows "Good until 5 October 2026" from `POST /auth/writer/token` and asks them to say that date when they hand the token over; the writers list says "good until"; the newcomer's screen says "This token is good until…" from the public `GET /auth/claim`. A token that is gone (410) is worded by why: expired sends the person to their group for a new one, which takes the group a moment; used tells them to sign in if that was them, and to tell the group if it was not. The API keeps that reason as a code but does not send it yet, so it is read from its sentence ("Claim token is expired."), and a `condition` field wins the day it arrives.

## Behind Android

Android does not have API pull requests #105 and #106 yet (as of its commit `09e4280`); in that respect this app is ahead. As of Android commit `356a743`, not yet in this app:

- **Spanish and Russian** (Android phase 9). Every string here is English, in the Swift source.
- **The push doorbell** (API pull request #96, Android phase 10). iPhones are reached through Firebase, so this needs a Firebase project with this app added to it (`GoogleService-Info.plist`), an APNs key from a paid Apple developer account uploaded there, the Push Notifications capability, and a notification service extension to replace the server's bland alert with wording made on the phone. None of that exists yet on either platform. It will change when the news arrives, not what is shown: a push carries nothing, and the feed below is where the news comes from either way. Registering the device (`POST /auth/device`) and the devices list belong with it.
- An accessibility pass (Android phase 7c). Fields and buttons are labelled for VoiceOver, but nothing has been listened to.

## What was verified, and what was not

As of 23 September 2026.

- **Verified by tests and tools.** All tests pass. Crypto interoperates with the API and libsodium.js in both directions. Against the live development servers: the directory, the offline download, a writer's threads, a group's queue and writers in server mode; and in end-to-end mode, a group member's key (wrapped by the Android app) opened with their password, the group key opened with that, and letters written by other clients decrypted. The app builds in Xcode, Debug and Release, with no warnings, including the asset catalog (icon, accent colour).
- **Seen on screen** (iPhone 17 simulator, iOS 26.5, against the local API in server mode, signed out): the Directory home page with featured prisoners, the prisoners list with its filters and with more rows loading as it scrolls, a prisoner's profile, the sign-in screen, and the Account tab with the offline directory downloaded on launch and the server's mode detected. That first run found two layout bugs, both fixed: interest tags wrapping onto a line whose height the row had not reserved, so the next row's divider ran through them; and "Est. release" breaking in the middle.
- **Seen since, signed in as a group member:** the print queue.
- **Account deletion, against a real API (20 September 2026).** On a throwaway server with API pull request #104 and its seeded account `user3`: the server refuses a wrong password with 403, the app's own check stops a wrong password before any delete request is sent, the account and its two conversations are still there afterwards, the right password deletes them, and signing in again is refused. The delete screen itself was not driven end to end in the simulator; its model is covered by unit tests.
- **Returned, moved and freed, against a real API (20 September 2026).** On a throwaway server at API pull request #106, server mode, with the writer's and the group member's side of the core layer: a mailed letter recorded as returned with reason and note, the writer's feed and letter showing it, sending it again refused before the return and accepted after, `resent_as` linking the two; a release holding the queued letter, the group's held list, printing refused with `LetterHeldError` and accepted with `release: true`; a move to a relay-only facility with two groups holding a letter as `choose_relay`, the directory offering both groups, the writer's choice lifting the hold and putting the letter in that group's queue. **Seen on screen** (iPhone 17 simulator, signed in as a group member, against a development API at pull request #105): the queue's five filters, a letter taken from queued to printed to mailed, the "It came back" sheet, the return recorded, and the returned letter in the conversation with its reason and the group's note. That look found two bugs, both fixed and under test: the Held filter listed everything on an API older than #106, and the conversation showed no note. **Not verified:** `reseal_needed` against a real end-to-end server (no test plays the phone's send-then-delete either; only the send and delete calls it is built from are tested); the hold notices, "Print it anyway" and "Choose who mails it" on screen (that server had no #106); and "Send it again" on screen (it needs the writer signed in).
- **Letter nights and group numbers, against a real API (21 September 2026).** On a throwaway server at the API's `main` with #111 and #112, freshly seeded (which works again since API pull request #107): queue rows arrive addressed without a prisoner lookup; three letters, one of them already printed, are refused together with "Letter 42: a printed letter cannot move to printed." and nothing moves; two moved together give their writer one feed entry, "2 of your letters have been printed."; a group under twenty publishes nothing, and after `lettersSentBefore` 25 and three mailings publishes "28", on its public page too. The returned, moved and freed test passes on that server as well. **Seen on screen as a writer:** the returned letter with the group's note, the advice for its reason, and "Send it again" opening the compose screen from its text. **Seen on screen as a group member**, against the development API: two anonymous test letters written, "Select several…" appearing once the list held two, both ticked and marked printed with one request ("2 letters marked as printed."), then marked mailed through "Mark 2 letters as mailed?"; and the group's numbers page, which went from 1 to 3. That look found one bug, fixed: the numbers page loaded once and then showed a stale count, and now reloads whenever it comes into view. **Not seen on screen:** a refused batch ("Nothing was changed. Letter N: …"; the live test covers the refusal itself), and the inactive-group notice, because no development server has a pending group.
- **Claim tokens, against a real API (21 September 2026).** On a throwaway server at the API's `main` with #113: an issued token is good for 14.0 days, the public claim lookup and the writers list give the same date, and a token made to expire in the scratch database answers 410 with `"error": "Claim token is expired."` and no `condition` field, which is what the app reads. The reworded screens were not looked at on the simulator.
- **Paper letters, against a real end-to-end API with the flag on (23 September 2026).** On a throwaway at the API's `main` (#118): a letter logged with no text came back `printed` with `paper: true`; the group's feed said "A paper letter is waiting to go out with your group's next batch."; the letter was absent from Queued and present under Printed; a photo added afterwards was opened by the group with the letter's key; marked mailed in a batch; a photo after that was refused with "Attachments of a mailed letter can no longer be changed."; a reply sent with `paper: true` by the group, which the app never sends, was refused with `400`, "paper is for outgoing letters" **Not seen on screen:** the switch, the card and the group's banner (they compile).
- **Invite codes, against a real end-to-end API with the flag on (23 September 2026).** On a throwaway server at the API's `main` (#118): `member1` issued two codes with a label; the newcomer's check, with the code typed in lower case and spaces, named the chapter and the date; a join with a taken username was refused and did not spend the code; the join went through split with the keys made on the phone, the account carried `sponsoredBy`, its next sign-in was one derivation, and a letter it sealed was read by the group from its queue; the chapter's list said one used and one unused; the used code and, after cancelling the batch, the other answered by their `condition`; over the quota, the API's sentence. **Not seen on screen:** the join screen and the slips (they compile; the simulator's dev server may not have #116). **For the API side:** a taken username answers `400` with only "Error joining with the invite code.", so the person cannot know what to fix.
- **Group roles, against a real end-to-end API with the flag on (23 September 2026).** On a throwaway server at the API's `main` with #115 and #117, with a second group admin created before the flag went on: `member1` set the key up at sign-in and the server made it the owner; `member2` signed in, got keys of their own, and appeared as waiting on `member1`'s list; `member2` was refused a hand-over; "Make owner" for the waiting admin was refused on the phone before any request; after the key was handed, the role passed, the old owner's loaded key said so and its next hand-over was refused by the server; both feeds carried the server's own events in the app's words ("You have been handed the group key…", "You are now your group's group-owner admin."); the new owner's deletion was refused with `condition: group_owner`. **Not seen on screen:** the key page and the delete page's "Not yet" for an owner (they compile; the simulator was signed out).
- **The split scheme, against a real end-to-end API with the flag on (22 September 2026).** On a throwaway server at the API's `main` with #114, `ENCRYPTION_MODE=e2e`, `REQUIRE_SPLIT_AUTH=true`: the handshake called every name split; `member1` (made before the flag) signed in by the fallback and got keys and the group key; its password change moved it to split, after which it signed in with one derivation to the same key and the old password was refused with no fallback; a managed writer added and a token issued in-app; the newcomer claimed split (the server says so), wrote a letter that the group read from its queue with the group key, signed out and in again and read it back, recovered with the code to a new split password keeping the key, was refused deletion with the old password and deleted with the new. That the password itself is in no request is proven by the unit tests' recorder, not live. **Not seen on screen:** the meter and the ten-character rule (the screens compile; the claim screen's meter can be looked at signed out), and the downgrade refusal (it needs a tampered server; the unit test plays one).
- **Not yet seen on screen.** The outbox (it needs the API to be unreachable, and the development server was in use); the rest behind sign-in: the writer's inbox, threads, compose and attachments, claim, recovery and the recovery-code screen, password change, and all of the group screens; the facilities and groups lists and pages; anything against the end-to-end server; the saved-copy banner with no connection; the camera and printing; an iPad; dark mode; large text sizes; VoiceOver. The logic behind those screens is tested; their layout is not. Expect more findings of the kind above. The "what to try by hand" lists in `../Android/docs/PLAN.md` apply unchanged.
