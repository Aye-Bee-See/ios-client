# ABC Mailbox for iOS

The iPhone and iPad client for Aye Bee See, a correspondence network for political prisoners. Writers find a prisoner, read the facility's mail rules, and write; a support group prints and mails the letter and records the reply.

It does what the Android client (`../Android`) did as of its phase 8 (19 September 2026), screen for screen, and speaks the same API and the same end-to-end encryption. What Android has since gained and this app has not is listed under "Behind Android" below. The Android documents remain the map: `../Android/docs/PLAN.md` for what is built and why, `../android-client-brief.md` for the API. This directory adds only what is particular to iOS:

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

That is the whole test suite: about 140 tests in a few seconds, on the Mac. It includes the crypto fixtures the Android client is tested against (made by the API's own `services/crypto.js` and by libsodium.js), and whole account, letter and group flows run against a stub server with real Argon2id and real sealed boxes.

To run the app, open `ABCMailbox.xcodeproj`, choose the `ABCMailbox` scheme and a simulator, and run. To sign and run on a phone, set your team under Signing & Capabilities.

Three more checks, each opt-in:

```bash
# The other direction of the crypto proof: libsodium.js opens what Swift produced.
# (`swift test` writes the fixture; `npm install` once in ../Android/tools.)
node tools/verify-swift-fixture.mjs

# The core layer against a running API. Read-only: it signs in and reads, never sends or changes anything.
cd ABCMailboxKit && ABC_LIVE_SERVER=http://localhost:3000 ABC_LIVE_E2E=http://localhost:3100 swift test --filter LiveServer

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

## Behind Android

As of Android commit `cbf93c3`, not yet in this app:

- **Spanish and Russian** (Android phase 9). Every string here is English, in the Swift source.
- **Push notifications and the notification feed** (API pull request #96). iPhones are reached through Firebase, so this needs a Firebase project with this app added to it (`GoogleService-Info.plist`), an APNs key from a paid Apple developer account uploaded there, the Push Notifications capability, and a notification service extension to replace the server's bland alert with wording made on the phone. The feed (`GET /auth/notifications`) needs none of that and could be built first.
- An accessibility pass (Android phase 7c). Fields and buttons are labelled for VoiceOver, but nothing has been listened to.

## What was verified, and what was not

As of 19 September 2026.

- **Verified by tests and tools.** All tests pass. Crypto interoperates with the API and libsodium.js in both directions. Against the live development servers: the directory, the offline download, a writer's threads, a group's queue and writers in server mode; and in end-to-end mode, a group member's key (wrapped by the Android app) opened with their password, the group key opened with that, and letters written by other clients decrypted. The app builds in Xcode, Debug and Release, with no warnings, including the asset catalog (icon, accent colour).
- **Seen on screen** (iPhone 17 simulator, iOS 26.5, against the local API in server mode, signed out): the Directory home page with featured prisoners, the prisoners list with its filters and with more rows loading as it scrolls, a prisoner's profile, the sign-in screen, and the Account tab with the offline directory downloaded on launch and the server's mode detected. That first run found two layout bugs, both fixed: interest tags wrapping onto a line whose height the row had not reserved, so the next row's divider ran through them; and "Est. release" breaking in the middle.
- **Seen since, signed in as a group member:** the print queue.
- **Not yet seen on screen.** The outbox (it needs the API to be unreachable, and the development server was in use); the rest behind sign-in: the writer's inbox, threads, compose and attachments, claim, recovery and the recovery-code screen, password change, and all of the group screens; the facilities and groups lists and pages; anything against the end-to-end server; the saved-copy banner with no connection; the camera and printing; an iPad; dark mode; large text sizes; VoiceOver. The logic behind those screens is tested; their layout is not. Expect more findings of the kind above. The "what to try by hand" lists in `../Android/docs/PLAN.md` apply unchanged.
