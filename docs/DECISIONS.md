# Decisions

Short records of choices that are not obvious from the code. Newest first. Decisions that the Android client made for both platforms (the wire formats, NFKC, keys in memory only, no key rotation in the app) are in `../../Android/docs/DECISIONS.md` and are not repeated here; this file is for what iOS had to decide for itself.

## 2026-09-21: several letters at once are all or none on the phone too

**Context.** API PR #111: `PUT /messaging/status/batch` moves up to 200 letters, all or none, and tells each writer once.

**Decisions.** Taken with Android's, so that a volunteer who uses both sees one behaviour.

- *More than 200 is refused, not split.* Two requests of 200 and 50 can half succeed, and the volunteer would have to work out which half. The limit is said before any request is made.
- *A held letter cannot be ticked.* Printing one needs `release: true`, which this app only ever sends from a confirmation about that one letter. A batch that released holds would make the decision an oversight again.
- *A refusal keeps the ticks.* The server's sentence names the letter that stopped the rest; the volunteer unticks it and tries again. Clearing the selection would make them find thirty letters twice.
- *"Changed by someone else meanwhile" is news, not an error.* It reloads and says how things stand. The brief says why: the letter is very probably already where the person wanted it.
- *An older API's "Cannot PUT" is translated.* As a 404 it would read "not found", which a volunteer would take for a missing letter.
- *An inactive group is a key state of its own* (`groupNotActive`), found by a 403 from a group key endpoint, because the key bundle says the same thing ("no key") for a group that has not set one up and a group that may not. It is shown in server mode too: such a group cannot print either.

## 2026-09-20: returned and held letters: the phone copies, the person decides

**Context.** API PRs #105 (a `returned` status with a reason, a note, and `resendOf`) and #106 (queued letters held when their prisoner is moved or freed; `release: true` to print one anyway).

**Decisions.**

- *The feed does not say why a letter came back, or who was moved.* Feed sentences end up on lock screens, so they name nobody and quote nothing, as before. "Transferred" next to a notification time is information about a prisoner. The reason is in the conversation.
- *Sending again copies on the phone, files included.* The server has no copy operation, on purpose. The compose screen loads the returned letter's text, relay note and attachments (downloaded, decrypted where needed, staged again) and sends a new letter with `resendOf`. The relay group is deliberately not copied: the point of routing afresh is that the person may be somewhere else. A file that cannot be fetched is named, and the letter can still be sent without it.
- *For `reseal_needed`, send first and delete second.* The API describes it as "delete and send again". In that order a failure in between loses the letter from the server; in this order it leaves two, one of them visibly held and deletable. For the same reason this path does not fall back to the outbox: queued offline, the new letter might go out days later while the held one is still there, and nothing would remove it.
- *Printing a held letter takes a different button and a confirmation.* The API made it a flag so that it is a decision; a client that always sent `release: true` would undo that. The flag is sent only from the confirmation. A `LetterHeldError` on an ordinary "Mark as printed" means the hold is newer than the screen: reload and show it, never retry with the flag.
- *The return note's limit and its warning are on the phone.* 200 characters is checked before sending. The sheet says the note is read by the writer and is not encrypted in any mode, because a volunteer used to end-to-end letters would otherwise assume it is.
- *Codes this version does not know still mean something.* An unknown return reason reads as "nothing says why"; an unknown hold reason is still a hold, shown as one, and still needs the confirmation to print. Reasons may be added after the groups are asked (the PR says so).

- *A held letter's chip says "On hold", and every return reason has advice* (21 September 2026, taken from Android). This app first kept the "Queued" chip and let the notice explain, and had one line of advice for the three reasons that doubt the address. Android's reasoning is better on both: "Queued" tells a writer that a group will print the letter, which for a held one is false; and a writer whose letter was refused needs to know what to do next as much as one whose letter found nobody. The chip changes on the conversation card and the group's letter page; the server's status, the queue filters and the inbox row are untouched. The advice uses Android's sentences and shows where "Send it again" does, until the letter has been sent again. Also Android's: after a return for `transferred`, `released` or `bad_address`, the member who recorded it is told that the directory needs correcting if the group knows where the person is now.
- *Only a letter that says it is held is shown as held.* First look at the Held filter on the simulator, against a development server one pull request behind: it listed every letter, because an API that does not know `held=true` ignores it. The page is checked on the phone (`heldReason` present, status queued); against a current API that changes nothing. The same lesson as the delete password: a filter that exists only on the server is a filter only on servers that have it.
- *A conversation's returned letters are completed on the phone.* `GET /chat/chat?full=true` sends letters without `status_history` and without `resent_as`, so on first look the group's note was missing, and "Send it again" would have been offered a second time. `resentAs` is rebuilt from the sibling letters' `resendOf`; each returned letter is read by itself for its history (returns are rare; a failure only means the note is not shown).

**Not built.** The `addressInDoubt` worklist and the `mail` report on a prisoner edit: the app has no directory editing.

## 2026-09-20: the phone proves the password before asking for a delete

**Context.** First real use of the delete screen, on the simulator: a wrong password deleted the account. The app had sent the wrong password faithfully; the development server had been started hours before API PR #104 was merged, and its `DELETE /auth/user` handler never reads `password`. It deleted on the token alone, which is what that endpoint did before the PR.

**Decision.** `AccountDeletion` signs in with the typed password first (as the change-password flow already does) and sends the delete only if that succeeds. A wrong password never reaches `DELETE /auth/user`.

**Why.** A guard that exists only on the server is a guard only against servers that have it. A deployed API can lag an app release exactly as that development server did, and this is the one action in the app that cannot be undone. The cost is one extra request. Wrong guesses are limited like failed sign-ins, and a 429 is shown as itself rather than as "wrong password".

**Consequences.** The server's own check (PR #104) still runs and is still honoured. `AccountDeletionTests` has a fake server from before the PR to keep this from regressing.

## 2026-09-20: four guards on deleting an account, and none of them is a delay

**Context.** `DELETE /auth/user` (API PR #104) removes a person and every letter they wrote or received. Nothing is kept and nobody can undo it. For some writers those letters are years of correspondence with someone in prison.

**Decision.** The link is the last thing on the Account tab and quiet. The screen first says what goes and what does not, in numbers where it can ("your 12 conversations"). Then: type the username (guards against a slip of the thumb; case and spaces forgiven, because it proves intent, not identity); the password (the server requires it, so a stolen token or a borrowed unlocked phone is not enough; a wrong one is answered "Nothing was deleted."); a checkbox, "I understand this cannot be undone", which must be ticked by hand (asked for by the project's owner: of the four it is the only one that makes a person read the sentence that matters most, and it stays ticked through a mistyped password, because their intent has not changed); and a final system confirmation whose destructive button says "Delete everything". The password field is cleared after every attempt.

**Rejected.** A countdown or a cooling-off period: the API deletes at once, so a delay on the phone would be theatre, and a person leaving because they are in danger should not be made to wait. Face ID in place of the password: the server could not verify it. Hiding the option from group members: it is their account too; the one case where it must not proceed (the last holder of a group's key) is explained before they type anything, with the way out.

**Consequences.** The phone deletes nothing of its own until the server confirms, so a failed or refused attempt loses nothing. After it succeeds, drafts and unsent letters for that account are removed as well: an unsent letter from a deleted account could never be sent, and would sit on the phone as plaintext-under-a-key for no one.

## 2026-09-19: the feed is a badge and a sentence, not a screen; permission is never asked at launch

**Context.** Android built the notification feed (API PR #96) as a badge on the Inbox tab and a system notification, with no list of entries: an entry says "a reply arrived on thread 12", and the Inbox already shows that thread at the top.

**Decision.** The same here. What differs is delivery. Android's WorkManager checks every six hours; iOS grants background refreshes at its own discretion, so most news will be found when the app is opened, and there a system notification is the wrong voice: the app says it as a toast and keeps the badge. Notification permission is asked from the Account tab (and when a letter is first queued offline), where the reason is on screen. iOS lets an app ask once; a prompt at launch spends that on a reflexive "Don't Allow".

**Consequences.** Until push exists, someone who never opens the app hears of a reply late. That is the case for building push, and the feed is the half of push that does the work: the doorbell will only make `ActivityRepository.sync` run sooner.

## 2026-09-19: the group key is handed over with one confirmation, not silently

**Context.** The API's migration guide (PR #95) has a group member's client do five things after sign-in "without asking". Step 3 is: for every member with keys of their own who does not hold the group key, seal it to them. The guide allows "quietly, or with one confirmation".

**Decision.** Steps 1, 2, 4 and 5 are silent (a toast says what was done). Step 3 is a notice on the Inbox naming who is waiting, with one button.

**Why.** Handing over the group key grants the means to read and print every letter sealed to the group, and who counts as a member is the server's word. A person glancing at two names is a cheap check on that. And the app already has a "Stop" button on the Group key screen that takes a member's copy away; done silently, the next sign-in of any holder would hand it straight back, and the button would be a lie.

**Consequences.** A new member may wait until a holder opens the app and taps once. The switch itself does not wait for them: it needs each relaying group to have a key (step 2), which is silent.

Also decided here: in server mode the group key banner stays hidden and none of this shows unless something was done. Before the switch the server reads for everyone, and "you have not been given the group key" would alarm a volunteer about something that does not affect them yet.

## 2026-09-19: the outbox sends when iOS allows, and says so

**Context.** Android's outbox hands the job to WorkManager: "when there is a network, even if the app is closed or the phone restarted". iOS has nothing with that guarantee.

**Decision.** Three triggers. While the app runs, `NWPathMonitor` flushes the outbox the moment a connection appears. The app also flushes at launch, on coming to the front, and after sign-in. For a closed app, a `BGProcessingTask` that requires a network is requested whenever the app goes to the background with letters waiting; its outcome is reported in a local notification that names nobody. The Inbox wording does not promise what Android's does.

**Consequences.** A letter written on the train and never looked at again may wait until the app is next opened. `Idempotency-Key` (API PR #97) is what makes all this safe to be sloppy about: any number of triggers may race, and a repeat is answered with the first attempt's letter. The outbox is files (one sealed blob per letter, in a folder per account), not a database, for the same reason drafts are. Permission for notifications is asked the first time a letter is queued, when the reason is obvious, and never at launch.

**Rejected.** A background `URLSession` upload, which iOS does complete for a closed app: it needs the request body on disk at queue time, and in end-to-end mode the letter cannot be sealed until the relay group's current public key has been fetched.

## 2026-09-19: where iOS deliberately differs from Android

The brief was "the same thing as the Android app", so each difference is listed with its reason.

| Android | iOS | Why |
| --- | --- | --- |
| Session and key vault in DataStore, AES-GCM under an Android Keystore key | Keychain items, `AfterFirstUnlockThisDeviceOnly` | The Keychain is the encrypted store; wrapping it in a second cipher adds nothing. `ThisDeviceOnly` is `allowBackup="false"`: the items never enter a backup or move to a new phone. |
| Nothing survives an uninstall | Keychain items do, so the first launch after an install wipes them | Otherwise a reinstall starts out signed in, holding the previous install's private key. `UserDefaults` dies with the app, so its absence marks a fresh install (`AppContainer`). |
| Drafts in Room, fields encrypted | One small AES-GCM file per draft, key in the Keychain, complete file protection, excluded from backup | The app has no other use for a database. |
| Offline directory in Room, filtered with SQL | One JSON file read into memory, filtered in Swift | A directory is hundreds of records. What has to match is behaviour, and `OfflineDirectoryTests` mirrors Android's `DirectoryCacheDaoTest` case for case. Written atomically, so a reader sees the old copy or the new one. Revisit if a directory passes about ten thousand records. |
| Attach with the document picker, or the camera | The same, plus "Choose a photo" | On an iPhone pictures live in Photos, not Files. Whatever comes from Photos or the camera is re-encoded as JPEG, because phones produce HEIC and the API takes JPEG, PNG, WebP and PDF. |
| The camera needs no permission (system camera through a `FileProvider`) | `NSCameraUsageDescription` | iOS has no permission-free camera hand-off. The button is hidden where there is no camera (the simulator). |
| Print through `PrintManager` and a `WebView` | `UIPrintInteractionController` with an HTML formatter | The same idea: the system's print panel, so the app needs no printer code. |
| Open an attachment in another app (`ACTION_VIEW`) | Quick Look, inside the app | A decrypted attachment need not be handed to another app to be read. It can still be shared from the preview. |
| Copy a token or recovery code to the clipboard | The same, but local-only and expiring after ten minutes | Otherwise Universal Clipboard offers a secret to the person's other devices. |
| A `Loading` session state while DataStore is read | None | Reading the Keychain is synchronous; the app knows whether it is signed in before the first frame. |
| Snackbars | A toast above the tab bar | iOS has no snackbar. |
| Hilt | `AppContainer`, by hand | About fifteen long-lived objects; a DI library would be more to learn than it saves. |
| `Group`, `Thread`, `Services` | `SupportGroup`, `LetterThread`, `ServiceLabels` | SwiftUI and Foundation already have a `Group` and a `Thread`. |
| Debug builds allow plain http to any host | Every build allows plain http to local addresses only (`NSAllowsLocalNetworking`) | One Info.plist serves both configurations, and the exception is harmless in release: it cannot reach the internet. A development hostname that is not `localhost`, an IP, or `*.local` needs https. |
| Emulator reaches the host as `10.0.2.2` | The simulator reaches it as `localhost` | The simulator shares the Mac's network stack. |

Two small things iOS fixes that Android still has: the compose screen reads who is signed in when it needs to rather than when it was built (someone who taps "Write a letter" signed out, then signs in, would otherwise have no drafts and, as a group member, no "writing as" line); and a downloaded end-to-end attachment is found in the cache the second time it is opened (the server can only report the ciphertext's size, which never equals the decrypted file's, so a size comparison alone downloads it again every time).

## 2026-09-19: everything that is not SwiftUI is a Swift package

**Context.** Android keeps crypto in a plain JVM module so that its tests run on the development machine. On Android that was for the crypto only, because libsodium's Android build cannot load on a desktop JVM and the app's tests fake it.

**Decision.** `ABCMailboxKit` holds two libraries: `ABCCrypto` (libsodium) and `ABCCore` (API client, session, repositories, domain). Both build for macOS as well as iOS, so `swift test` runs everything in seconds with no simulator. Because libsodium runs natively on a Mac, the app-level tests use the real crypto against a stub server: a letter in a test is really sealed and really opened.

**Consequences.** Types the views use are `public`; DTOs and requests stay internal to the package, so the views cannot reach past the repositories. View models live in the app target and are not unit tested; they are thin (state, a call, an error sentence) and the logic they call is tested.

## 2026-09-19: libsodium through swift-sodium's `Clibsodium`

**Context.** The contract is libsodium's primitives (X25519 sealed boxes, XChaCha20-Poly1305, Argon2id) and the clients must use the same library family.

**Decision.** Depend on `jedisct1/swift-sodium` (maintained by libsodium's author) and use only its `Clibsodium` product: the prebuilt XCFramework and C headers. `Sodium.swift` calls the C functions directly, by their libsodium names, and is the only file that does.

**Why not the package's Swift wrapper.** Calling C directly keeps the byte handling in view. The Android binding's wrapper hid a bug for non-ASCII passwords (it passed a UTF-16 length as a byte length); here `deriveKey` builds the UTF-8 bytes itself and passes their count.

**Rejected.** CryptoKit (has X25519 and ChaChaPoly, but no XChaCha20, no sealed boxes, no Argon2id). Building libsodium ourselves (a build to maintain, for no gain while a maintained binary exists).

## 2026-09-19: iOS 17 minimum

The Observation framework (`@Observable`) is what makes the core layer's state (`SessionRepository`, `GroupKeyring`, `PagedLoader`) directly readable from SwiftUI with no adapter layer. It needs iOS 17. In 2026 that excludes almost no phone that can run a current browser.

## 2026-09-19: the project file is written by hand, and small

`project.pbxproj` uses Xcode 16's file-system-synchronised group for `ABCMailbox/`: the project lists no source files, so adding a Swift file to that folder needs no project edit and causes no merge conflict. Info.plist is generated from build settings, with `Config/Info.plist` supplying the keys that cannot be (URL scheme, ATS exception, `APIBaseURL = $(API_BASE_URL)`). The API address is a build setting per configuration, as `BuildConfig.API_BASE_URL` is on Android.
