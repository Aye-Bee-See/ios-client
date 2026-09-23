@testable import ABCCore
import ABCCrypto
import Foundation

/// A small in-memory imitation of the API in end-to-end mode: enough of `/auth`
/// and `/messaging` to run whole flows. It stores exactly what a client sends,
/// the way the real server does, and never sees a private key or a plaintext,
/// so whatever the tests read back was opened with real libsodium on this side.
final class FakeAPI: @unchecked Sendable {
  struct Account {
    var id: Int
    var username: String
    var password: String
    var role = "user"
    var chapterId: Int?
    var managedBy: Int?
    var keys: [String: Any] = [:] // publicKey, wrappedPrivateKey, kdfSalt, kdfParams, recovery…
    var orgWrappedPrivateKey: String? // custody copy, while unclaimed
    var claim: [String: Any]? // tokenHash, claimWrappedPrivateKey, claimSalt, claimKdfParams
    var name: String?
    /// The group's shared anonymous writer: not a person, and never has keys.
    var anonymousFor: Int?
    /// The chapter whose invite code made the account (API PR #116).
    var sponsoredBy: Int?
    /// API PR #114. For a split account `password` holds the auth key (44 characters of base64) and `keys` the
    /// `kdfSalt`/`kdfParams` the auth key was derived with, as on the server, where they are the same columns.
    var authScheme = "plain"
  }

  private let lock = NSLock()
  var mode = "e2e"
  var accounts: [Account] = []
  var messages: [[String: Any]] = []
  var attachments: [Int: (meta: [String: Any], bytes: Data)] = [:]
  var groupKeys: [Int: (publicKey: String, version: Int)] = [:]
  var memberKeys: [Int: [Int: String]] = [:] // group -> member -> sealed group private key
  var tokens: [String: Int] = [:]
  /// The notification feed, per account, as the API keeps it: ids and states, never content (PR #96).
  var notifications: [Int: [[String: Any]]] = [:]
  private var nextNotification = 40
  var challenges: [String: String] = [:] // username -> challenge (base64)
  /// Answer the next matching request with this instead (one shot), e.g. a 409 to simulate a key rotation.
  var intercept: ((Recorded) -> Stubbed?)?
  /// An API build from before PR #104: `DELETE /auth/user` never reads `password` and deletes one's own account on the token alone.
  var predatesPasswordOnDelete = false
  /// An API from before PR #106: `held` is not a filter it knows, so it is ignored.
  var predatesHeldLetters = false
  /// An API from before PR #111: queue rows name the prisoner by id only, and there is no batch address.
  var predatesLetterNights = false
  /// Groups waiting for approval, or suspended: every group key endpoint answers 403 (the brief of 21 September, 1.10).
  var inactiveGroups: Set<Int> = []
  /// A group's numbers (API PR #112), by group id. `lettersSent` stays null until before + counted reaches twenty.
  var lettersSentBefore: [Int: Int] = [:]
  var lettersCounted: [Int: Int] = [:]
  /// An API from before PR #112 sends none of the counting fields.
  var predatesGroupNumbers = false
  /// An API from before PR #114: no handshake (404), and every password is the password.
  var predatesSplitAuth = false
  /// REQUIRE_SPLIT_AUTH: the handshake calls every name split, and no new plain account can be made.
  var requireSplitAuth = false
  /// How many times the handshake was asked, per username (a test can check nothing else was tried).
  var handshakes: [String: Int] = [:]
  /// Group roles (API PR #115): the chapter's group-owner admin, by group id. The first group admin to set up the key becomes it.
  var owners: [Int: Int] = [:]
  /// An API from before PR #115: no `owner` or `waiting` in the members list, no ownership endpoint, any holder may hand the key.
  var predatesGroupRoles = false
  /// Invite codes (API PR #116): each code, normalised, with its batch, chapter and state; batches with their labels.
  var inviteCodes: [String: (batch: String, chapter: Int, state: String)] = [:]
  var inviteBatches: [String: (chapter: Int, label: String?, expiresAt: String, createdAt: String)] = [:]
  var inviteLimit = 20
  private var nextBatch = 0
  /// The phone has no connection: every request fails before it leaves.
  var noSignal = false
  /// One shot: the next request matching this is carried out, and then its answer is lost on the way
  /// back (a timeout, a tunnel). The server has the letter; the phone does not know.
  var loseAnswerTo: ((Recorded) -> Bool)?
  /// Idempotency-Key -> what it made (API PR #97).
  private var keys: [String: (fingerprint: String, id: Int)] = [:]
  private var nextId = 100

  func handle(_ r: Recorded) -> Stubbed {
    lock.withLock {
      if noSignal { return Stubbed(status: -1) }
      let answer = idempotent(r)
      if let lose = loseAnswerTo, lose(r) { loseAnswerTo = nil; return Stubbed(status: -1) }
      return answer
    }
  }

  /// The same key again returns what the first attempt made, marked as a replay; a key reused for a
  /// different letter is a 422; a key whose letter was deleted since is a 410. Refusals free the key.
  private func idempotent(_ r: Recorded) -> Stubbed {
    guard r.method == "POST", let key = r.headers["Idempotency-Key"], let who = caller(r)?.id else { return route(r) }
    let isLetter = r.path == "/messaging/message"
    let fingerprint: String
    if isLetter {
      fingerprint = "\(who)|\(r.json["prisoner"] ?? "")|\(r.json["sender"] ?? "")|\(r.json["user"] ?? "")|\(r.json["messageText"] ?? "")"
    } else {
      let parts = Multipart(r)
      fingerprint = "\(who)|\(parts.fields["message"] ?? "")|\(parts.filename ?? "")|\(parts.file.count)"
    }
    if let known = keys[key] {
      guard known.fingerprint == fingerprint else { return .error(422, info: "Error sending.", extra: ["name": "IdempotencyError", "error": "This Idempotency-Key was used for a different request."]) }
      if isLetter {
        guard let m = messages.first(where: { $0["id"] as? Int == known.id }), let a = caller(r) else { return .error(410, info: "That letter was deleted.") }
        return .json(["data": visible(m, to: a), "success": true, "status": 201], status: 201, headers: ["Idempotent-Replayed": "true"])
      }
      guard let file = attachments[known.id] else { return .error(410, info: "That file was deleted.") }
      return .json(["data": file.meta, "success": true, "status": 201], status: 201, headers: ["Idempotent-Replayed": "true"])
    }
    let answer = route(r)
    if (200..<300).contains(answer.status), let made = ((try? JSONSerialization.jsonObject(with: answer.body)) as? [String: Any])?["data"] as? [String: Any], let id = made["id"] as? Int {
      keys[key] = (fingerprint, id)
    }
    return answer
  }

  private func id() -> Int { nextId += 1; return nextId }

  /// Something happened that `user` should hear about.
  func tell(_ user: Int, _ event: String, chat: Int? = 12, message: Int? = nil, detail: [String: Any]? = nil) {
    lock.withLock { tellLocked(user, event, chat: chat, message: message, detail: detail) }
  }

  /// For the routes, which already run under the lock.
  private func tellLocked(_ user: Int, _ event: String, chat: Int?, message: Int?, detail: [String: Any]?) {
    nextNotification += 1
    notifications[user, default: []].insert(["id": nextNotification, "event": event, "chat": chat ?? NSNull(), "message": message ?? NSNull(), "submission": NSNull(), "detail": detail ?? NSNull(), "readAt": NSNull(), "createdAt": "2026-09-19T10:00:00.000Z"], at: 0)
  }
  /// The directory learned that a prisoner was moved or freed (API PR #106): their queued letters are held
  /// and everyone who writes to them is told how many of their letters are waiting.
  func directoryLearns(prisoner: Int, event: String, holding reason: String) {
    var waiting: [Int: Int] = [:]
    lock.withLock {
      for i in messages.indices where messages[i]["prisoner"] as? Int == prisoner && messages[i]["status"] as? String == "queued" && messages[i]["sender"] as? String != "prisoner" {
        messages[i]["heldReason"] = reason
        waiting[messages[i]["user"] as? Int ?? 0, default: 0] += 1
      }
    }
    let writers = Set(lock.withLock { messages.filter { $0["prisoner"] as? Int == prisoner }.compactMap { $0["user"] as? Int } })
    for writer in writers {
      let detail: [String: Any] = event == "prisoner.moved" ? ["prisoner": prisoner, "prison": 2, "held": waiting[writer] ?? 0] : ["prisoner": prisoner, "status": "free", "held": waiting[writer] ?? 0]
      tell(writer, event, chat: prisoner, detail: detail)
    }
  }

  private let defaultKdfParams: [String: Any] = ["kdf": "argon2id", "alg": 2, "opslimit": 2, "memlimit": 67_108_864]

  /// API PR #114, wherever a password is set: `authScheme: "split"` needs a salt and a recipe and an auth-key-shaped
  /// password, and takes; a split account never goes back to plain (409); under the flag no new plain account is made.
  private func scheme(_ body: [String: Any], for i: Int, creating: Bool) -> Stubbed? {
    let requested = body["authScheme"] as? String ?? "plain"
    guard ["plain", "split"].contains(requested) else { return .error(400, extra: ["errors": ["authScheme must be one of plain, split."]]) }
    if requested == "split" {
      guard body["kdfSalt"] != nil, body["kdfParams"] != nil else { return .error(400, extra: ["errors": ["authScheme \"split\" needs kdfSalt and kdfParams (the auth key is derived from them, as the wrap key is)."]]) }
      guard SplitAuth.looksLikeAuthKey(body["password"] as? String ?? "") else { return .error(400, extra: ["errors": ["A split password is the auth key: 44 characters of base64."]]) }
      accounts[i].authScheme = "split"
      return nil
    }
    if accounts[i].authScheme == "split", !creating { return .error(409, info: "Error updating user.", extra: ["name": "AuthSchemeError", "error": "This account signs in without sending its password; it cannot go back."]) }
    if requireSplitAuth { return .error(400, extra: ["errors": ["This server no longer creates accounts that send their password (REQUIRE_SPLIT_AUTH)."]]) }
    return nil
  }

  /// An optional id as JSON: the number, or null.
  private func orNull(_ id: Int?) -> Any { id.map { $0 as Any } ?? NSNull() }
  private static let ownerOnly = "Only the group-owner admin of this chapter can hand its key to a group admin, take it away, or rotate it."
  private func admins(of g: Int) -> [Account] { accounts.filter { $0.role == "chapter" && $0.chapterId == g } }
  /// Every group admin of the chapter but the actor is told (API PR #115).
  private func tellAdmins(of g: Int, except actor: Int, _ event: String, detail: [String: Any]) {
    for a in admins(of: g) where a.id != actor { tellLocked(a.id, event, chat: nil, message: nil, detail: detail) }
  }

  private func prisonerJSON(_ pid: Int) -> [String: Any] {
    ["id": pid, "chosenName": "Jane Smith", "birthName": "John Smith", "prison": 1, "inmateID": "A-\(pid)", "prison_details": ["id": 1, "prisonName": "Test Prison", "country": "United States"]]
  }

  private func caller(_ r: Recorded) -> Account? {
    guard let header = r.headers["Authorization"], let id = tokens[String(header.dropFirst("Bearer ".count))] else { return nil }
    return accounts.first { $0.id == id }
  }
  private func index(_ id: Int) -> Int? { accounts.firstIndex { $0.id == id } }
  private func userJSON(_ a: Account) -> [String: Any] {
    ["id": a.id, "username": a.username, "role": a.role, "chapterId": a.chapterId ?? NSNull(), "name": a.name ?? NSNull(), "managedBy": a.managedBy ?? NSNull(), "publicKey": a.keys["publicKey"] ?? NSNull(), "sponsoredBy": a.sponsoredBy ?? NSNull()]
  }
  private func bundle(_ a: Account) -> [String: Any] {
    var b: [String: Any] = [:]
    for k in ["publicKey", "wrappedPrivateKey", "kdfSalt", "kdfParams"] { b[k] = a.keys[k] ?? NSNull() }
    b["hasRecovery"] = a.keys["recoveryWrappedPrivateKey"] != nil
    if let g = a.chapterId, a.role == "chapter" {
      b["orgKey"] = ["chapterId": g, "chapterPublicKey": groupKeys[g]?.publicKey ?? NSNull(), "wrappedOrgPrivateKey": memberKeys[g]?[a.id] ?? NSNull(), "keyVersion": groupKeys[g]?.version ?? NSNull(),
                     "owner": predatesGroupRoles ? NSNull() : orNull(owners[g]), "isOwner": !predatesGroupRoles && owners[g] == a.id]
    }
    return b
  }
  private func issue(_ a: Account) -> [String: Any] {
    let token = "token-\(a.id)-\(id())"
    tokens[token] = a.id
    return ["token": token, "expires": 1_800_000_000_000.0]
  }
  /// `envelopes` is filtered to the caller, as the real API does.
  private func visible(_ m: [String: Any], to a: Account) -> [String: Any] {
    var out = m
    let all = m["envelopes"] as? [[String: Any]] ?? []
    out["envelopes"] = all.filter { e in
      let type = e["readerType"] as? String, reader = e["readerId"] as? Int
      if type == "user" { return reader == a.id || accounts.contains { $0.id == reader && $0.managedBy != nil && $0.managedBy == a.chapterId } }
      return reader == a.chapterId
    }.map { e in e.filter { $0.key != "keyVersion" } }
    out["attachments"] = attachments.values.map(\.meta).filter { $0["message"] as? Int == m["id"] as? Int }
    out["resent_as"] = messages.filter { $0["resendOf"] as? Int == m["id"] as? Int }.map { ["id": $0["id"] ?? 0, "status": $0["status"] ?? "queued", "createdAt": $0["createdAt"] ?? NSNull()] as [String: Any] }
    return out
  }

  private func route(_ r: Recorded) -> Stubbed {
    if let answer = intercept?(r) { intercept = nil; return answer }
    let body = r.json
    switch (r.method, r.path) {
    case ("GET", "/health"):
      return .json(["status": "ok", "encryptionMode": mode])

    case ("POST", "/auth/invite-codes"):
      guard let a = caller(r), a.role == "chapter", let g = a.chapterId else { return .error(403, info: "Forbidden") }
      if inactiveGroups.contains(g) { return .error(403, info: "Your group is waiting for network approval.") }
      guard let count = body["count"] as? Int, (1...50).contains(count) else { return .error(400, extra: ["errors": ["count must be between 1 and 50."]]) }
      if let label = body["label"] as? String, label.count > 80 { return .error(400, extra: ["errors": ["label can be at most 80 characters."]]) }
      let outstanding = inviteCodes.values.filter { $0.chapter == g && $0.state == "unused" }.count
      if outstanding + count > inviteLimit { return .error(409, info: "Error issuing invite codes.", extra: ["name": "InviteQuotaError", "error": "This chapter has \(outstanding) unused codes and may have \(inviteLimit); \(count) more would go over."]) }
      nextBatch += 1
      let batch = "batch\(nextBatch)"
      let days = body["days"] as? Int ?? 30
      let expires = "2026-10-\(String(format: "%02d", min(22, days)))T19:00:00.000Z"
      inviteBatches[batch] = (g, body["label"] as? String, expires, "2026-09-23T10:00:00.000Z")
      var codes: [String] = []
      for _ in 0..<count {
        let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        let code = String((0..<12).map { _ in alphabet.randomElement()! })
        inviteCodes[code] = (batch, g, "unused")
        codes.append(InviteCode.pretty(code))
      }
      return .json(["data": ["chapter": g, "batch": batch, "label": body["label"] ?? NSNull(), "expiresAt": expires, "codes": codes, "outstanding": outstanding + count, "limit": inviteLimit], "info": "Invite codes issued. They are shown once.", "success": true, "status": 201], status: 201)

    case ("GET", "/auth/invite-codes"):
      guard let a = caller(r), a.role == "chapter", let g = a.chapterId else { return .error(403, info: "Forbidden") }
      let mine = inviteBatches.filter { $0.value.chapter == g }.sorted { $0.key > $1.key }
      let batches = mine.map { (id, b) -> [String: Any] in
        let codes = inviteCodes.values.filter { $0.batch == id }
        return ["batch": id, "label": b.label ?? NSNull(), "createdAt": b.createdAt, "expiresAt": b.expiresAt, "total": codes.count,
                "used": codes.filter { $0.state == "used" }.count, "cancelled": codes.filter { $0.state == "cancelled" }.count,
                "expired": codes.filter { $0.state == "expired" }.count, "unused": codes.filter { $0.state == "unused" }.count]
      }
      return .data(["chapter": g, "outstanding": inviteCodes.values.filter { $0.chapter == g && $0.state == "unused" }.count, "limit": inviteLimit, "batches": batches])

    case ("DELETE", "/auth/invite-codes"):
      guard let a = caller(r), a.role == "chapter", let g = a.chapterId else { return .error(403, info: "Forbidden") }
      var cancelled = 0
      for (code, c) in inviteCodes where c.chapter == g && c.state == "unused" && (body["all"] as? Bool == true || c.batch == body["batch"] as? String) {
        inviteCodes[code] = (c.batch, c.chapter, "cancelled"); cancelled += 1
      }
      return .data(["cancelled": cancelled, "outstanding": inviteCodes.values.filter { $0.chapter == g && $0.state == "unused" }.count])

    case ("GET", "/auth/join"), ("POST", "/auth/join"):
      // Public: never a token. The code is folded as the server folds it.
      let typed = r.method == "GET" ? (r.query["code"] ?? "") : (body["code"] as? String ?? "")
      let code = InviteCode.normalise(typed)
      guard let c = inviteCodes[code] else { return .error(404, info: "This invite code is not valid.", extra: ["name": "InviteCodeError", "error": "Invite code is unknown.", "condition": "unknown"]) }
      let inactive = inactiveGroups.contains(c.chapter)
      if c.state != "unused" || inactive {
        let condition = inactive ? "inactive" : c.state
        return .error(410, info: inactive ? "The chapter that issued this invite code is not active." : "This invite code is \(c.state).", extra: ["name": "InviteCodeError", "error": "Invite code is \(condition).", "condition": condition])
      }
      let chapter: [String: Any] = ["id": c.chapter, "name": "Test Chapter"]
      if r.method == "GET" { return .data(["chapter": chapter, "expiresAt": inviteBatches[c.batch].map { $0.expiresAt as Any } ?? NSNull()]) }
      guard let username = body["username"] as? String, (3...16).contains(username.count) else { return .error(400, extra: ["errors": ["username must be 3 to 16 characters."]]) }
      if accounts.contains(where: { $0.username == username }) { return .error(400, extra: ["errors": ["That username is taken."]]) }
      guard body["password"] is String else { return .error(400, extra: ["errors": ["password is required."]]) }
      var made = Account(id: id(), username: username, password: body["password"] as! String, name: body["name"] as? String)
      accounts.append(made)
      let i = accounts.count - 1
      if let refused = scheme(body, for: i, creating: true) { accounts.removeLast(); return refused }
      if mode == "e2e", body["publicKey"] != nil, body["wrappedPrivateKey"] == nil { accounts.removeLast(); return .error(400, extra: ["errors": ["publicKey must come with wrappedPrivateKey, kdfSalt and kdfParams."]]) }
      for k in ["publicKey", "wrappedPrivateKey", "kdfSalt", "kdfParams", "recoveryWrappedPrivateKey", "recoverySalt", "recoveryKdfParams"] { if let v = body[k] { accounts[i].keys[k] = v } }
      accounts[i].sponsoredBy = c.chapter
      made = accounts[i]
      inviteCodes[code] = (c.batch, c.chapter, "used")
      let user = userJSON(made)
      return .json(["data": ["user": user, "chapter": chapter], "success": true, "status": 201], status: 201)

    case ("GET", "/auth/login-params"):
      // Public, and never says whether an account exists: an unknown or plain name gets a made-up but stable salt.
      if predatesSplitAuth { return .error(404, info: "Cannot GET /auth/login-params") }
      if r.headers["Authorization"] != nil { return .error(400, info: "the handshake must not carry a token (the test's rule, so that a signed-out check is the same as a signed-in one)") }
      let name = r.query["username"] ?? ""
      handshakes[name, default: 0] += 1
      let a = accounts.first { $0.username == name }
      let split = a?.authScheme == "split" && a?.keys["kdfSalt"] != nil
      let plain = a != nil && !split && !requireSplitAuth
      let fakeSalt = Sodium.toBase64(Data(SecretCodes.hashHex(name).utf8.prefix(16)))
      return .data(["scheme": plain ? "plain" : "split", "kdfSalt": split ? a!.keys["kdfSalt"]! : fakeSalt, "kdfParams": split ? a!.keys["kdfParams"]! : defaultKdfParams])

    case ("POST", "/auth/login"):
      guard let a = accounts.first(where: { $0.username == body["username"] as? String && $0.password == body["password"] as? String }) else { return .error(401, info: "Incorrect username or password.") }
      var data: [String: Any] = ["user": userJSON(a), "token": issue(a)]
      if mode == "e2e" { data["keys"] = bundle(a) }
      return .data(data)

    case ("POST", "/auth/logout"):
      if let header = r.headers["Authorization"] { tokens[String(header.dropFirst("Bearer ".count))] = nil }
      return .data([:])

    case ("GET", "/auth/keys"):
      guard let a = caller(r) else { return .error(401, info: "Sign in.") }
      return .data(bundle(a))

    case ("PUT", "/auth/keys"):
      guard let a = caller(r), let i = index(a.id) else { return .error(401, info: "Sign in.") }
      if accounts[i].keys["publicKey"] != nil, body["publicKey"] != nil { return .error(409, info: "The public key is already set.") }
      // The first public key must come with its wrapped private half, or letters sealed to it could never be opened (PR #95).
      if accounts[i].keys["publicKey"] == nil, body["publicKey"] != nil, body["wrappedPrivateKey"] == nil || body["kdfSalt"] == nil || body["kdfParams"] == nil {
        return .error(400, extra: ["errors": ["publicKey must come with wrappedPrivateKey, kdfSalt and kdfParams."]])
      }
      let first = accounts[i].keys["publicKey"] == nil && body["publicKey"] != nil
      accounts[i].keys.merge(body) { $1 }
      let mine = messages.filter { $0["user"] as? Int == a.id }.count
      return .data(first ? ["caughtUp": ["letters": mine, "sealed": mine, "dropped": 0]] : [:])

    case ("GET", "/auth/public-key"):
      if let user = r.query["user"].flatMap(Int.init) { return .data(["user": user, "publicKey": accounts.first { $0.id == user }?.keys["publicKey"] ?? NSNull()]) }
      let g = r.query["chapter"].flatMap(Int.init) ?? 0
      return .data(["chapter": g, "publicKey": groupKeys[g]?.publicKey ?? NSNull(), "keyVersion": groupKeys[g]?.version ?? 0])

    case ("PUT", "/auth/user"):
      guard let a = caller(r), let target = body["id"] as? Int, let i = index(target) else { return .error(401, info: "Sign in.") }
      if let password = body["password"] as? String {
        if let refused = scheme(body, for: i, creating: false) { return refused }
        accounts[i].password = password
        for k in ["wrappedPrivateKey", "kdfSalt", "kdfParams"] { if let v = body[k] { accounts[i].keys[k] = v } }
        tokens = tokens.filter { $0.value != target }
        return .data(["token": issue(accounts[i])])
      }
      if body["publicKey"] != nil, accounts[i].anonymousFor != nil { return .error(409, info: "A group's anonymous account never has keys.") }
      if body["publicKey"] != nil, body["orgWrappedPrivateKey"] == nil || body["orgKeyVersion"] == nil { return .error(400, extra: ["errors": ["publicKey must come with orgWrappedPrivateKey and orgKeyVersion."]]) }
      if let publicKey = body["publicKey"] as? String, accounts[i].managedBy == a.chapterId {
        accounts[i].keys["publicKey"] = publicKey
        accounts[i].orgWrappedPrivateKey = body["orgWrappedPrivateKey"] as? String
      }
      return .data([:])

    case ("DELETE", "/auth/user"):
      // API PR #104: the person goes, with everything they wrote and received.
      guard let a = caller(r), let target = body["id"] as? Int, let i = index(target) else { return .error(401, info: "Sign in.") }
      guard target == a.id else { return .error(403, info: "Not yours to delete.") }
      guard predatesPasswordOnDelete || body["password"] as? String == a.password else { return .error(403, info: "Incorrect password.") }
      if a.anonymousFor != nil { return .error(409, info: "A group's shared anonymous account cannot be deleted.", extra: ["name": "AccountDeleteError", "condition": "anonymous"]) }
      // API PR #115: a group-owner admin cannot leave while the chapter has other group admins. PR #117: a condition names why.
      if !predatesGroupRoles, let g = a.chapterId, owners[g] == a.id, admins(of: g).count > 1 {
        return .error(409, info: "Error deleting user.", extra: ["name": "AccountDeleteError", "condition": "group_owner", "error": "A group-owner admin cannot delete their account while the chapter has other group admins: hand ownership on first."])
      }
      if mode == "e2e", let g = a.chapterId, memberKeys[g]?[a.id] != nil, (memberKeys[g] ?? [:]).count == 1 {
        return .error(409, info: "Error deleting user.", extra: ["name": "AccountDeleteError", "condition": "last_key_holder", "error": "You are the last holder of your group's key. Hand it to another member first, or the group could never read its letters again."])
      }
      let theirs = messages.filter { $0["user"] as? Int == target }
      let ids = Set(theirs.compactMap { $0["id"] as? Int })
      let files = attachments.filter { ids.contains($0.value.meta["message"] as? Int ?? -1) }.map(\.key)
      messages.removeAll { $0["user"] as? Int == target }
      files.forEach { attachments[$0] = nil }
      accounts.remove(at: i)
      tokens = tokens.filter { $0.value != target }
      notifications[target] = nil
      if let g = a.chapterId { memberKeys[g]?[target] = nil }
      let replies = theirs.filter { $0["sender"] as? String == "prisoner" }.count
      return .data(["deleted": 1, "letters": theirs.count - replies, "replies": replies, "attachments": files.count, "threads": theirs.isEmpty ? 0 : 1])

    case ("GET", "/auth/recover"):
      guard let a = accounts.first(where: { $0.username == r.query["username"] }), let publicKey = a.keys["publicKey"] as? String, a.keys["recoveryWrappedPrivateKey"] != nil else { return .error(404, info: "No recovery.") }
      let challenge = Sodium.randomBytes(32)
      challenges[a.username] = Sodium.toBase64(challenge)
      return .data([
        "publicKey": publicKey, "recoveryWrappedPrivateKey": a.keys["recoveryWrappedPrivateKey"]!, "recoverySalt": a.keys["recoverySalt"]!, "recoveryKdfParams": a.keys["recoveryKdfParams"]!,
        "sealedChallenge": Sodium.toBase64(try! Sodium.seal(challenge, to: Sodium.fromBase64(publicKey))),
      ])

    case ("POST", "/auth/recover"):
      guard let username = body["username"] as? String, let i = accounts.firstIndex(where: { $0.username == username }), challenges[username] == body["challenge"] as? String else { return .error(401, info: "Recovery refused.") }
      challenges[username] = nil
      if let refused = scheme(body, for: i, creating: false) { return refused }
      accounts[i].password = body["password"] as! String
      for k in ["wrappedPrivateKey", "kdfSalt", "kdfParams"] { accounts[i].keys[k] = body[k] }
      return .data([:])

    case ("GET", "/auth/claim"):
      let hash = SecretCodes.hashHex(r.query["token"] ?? "")
      guard let a = accounts.first(where: { $0.claim?["tokenHash"] as? String == hash }) else { return .error(404, info: "Unknown token.") }
      var data: [String: Any] = ["writer": ["id": a.id, "name": a.name ?? a.username], "chapter": ["id": a.managedBy ?? 0, "name": "Test Chapter"], "expiresAt": "2026-09-22T10:00:00.000Z"]
      for k in ["claimWrappedPrivateKey", "claimSalt", "claimKdfParams"] { data[k] = a.claim?[k] ?? NSNull() }
      data["publicKey"] = a.keys["publicKey"] ?? NSNull()
      return .data(data)

    case ("POST", "/auth/claim"):
      let hash = SecretCodes.hashHex(body["token"] as? String ?? "")
      guard let i = accounts.firstIndex(where: { $0.claim?["tokenHash"] as? String == hash }) else { return .error(410, info: "Used or expired.") }
      if let refused = scheme(body, for: i, creating: true) { return refused }
      accounts[i].username = body["username"] as! String
      accounts[i].password = body["password"] as! String
      for k in ["wrappedPrivateKey", "kdfSalt", "kdfParams", "recoveryWrappedPrivateKey", "recoverySalt", "recoveryKdfParams"] { if let v = body[k] { accounts[i].keys[k] = v } }
      accounts[i].claim = nil
      accounts[i].managedBy = nil
      accounts[i].orgWrappedPrivateKey = nil // the group's copy is deleted on claim
      return .json(["data": [:], "success": true, "status": 201], status: 201)

    case ("GET", "/auth/writers"):
      guard let a = caller(r) else { return .error(401, info: "Sign in.") }
      return .data(accounts.filter { $0.managedBy != nil && $0.managedBy == a.chapterId }.map { w -> [String: Any] in
        ["id": w.id, "name": w.name ?? w.username, "username": w.username, "email": "w\(w.id)@managed.example", "managedBy": w.managedBy!, "anonymousForChapter": w.anonymousFor ?? NSNull(), "publicKey": w.keys["publicKey"] ?? NSNull(), "orgWrappedPrivateKey": w.orgWrappedPrivateKey ?? NSNull(), "claimToken": w.claim.map { _ in ["expiresAt": "2099-01-01T00:00:00.000Z"] } ?? NSNull()]
      })

    case ("POST", "/auth/writer"):
      guard let a = caller(r), let g = a.chapterId else { return .error(403, info: "Not a member.") }
      if let version = body["orgKeyVersion"] as? Int, version != groupKeys[g]?.version { return .error(409, info: "Key version.", extra: ["name": "KeyVersionError"]) }
      var w = Account(id: id(), username: "managed-\(nextId)", password: UUID().uuidString, managedBy: g, name: body["name"] as? String)
      if let publicKey = body["publicKey"] { w.keys["publicKey"] = publicKey }
      w.orgWrappedPrivateKey = body["orgWrappedPrivateKey"] as? String
      accounts.append(w)
      return .data(["id": w.id, "name": w.name!, "username": w.username, "managedBy": g, "publicKey": w.keys["publicKey"] ?? NSNull(), "orgWrappedPrivateKey": w.orgWrappedPrivateKey ?? NSNull()])

    case ("POST", "/auth/writer/token"):
      guard let i = (body["writer"] as? Int).flatMap(index) else { return .error(404, info: "No such writer.") }
      if body["tokenHash"] == nil { // server mode: the server makes the token
        let token = SecretCodes.generate()
        accounts[i].claim = ["tokenHash": SecretCodes.hashHex(token)]
        return .data(["writer": accounts[i].id, "token": token, "expiresAt": "2026-09-22T10:00:00.000Z"])
      }
      accounts[i].claim = body.filter { $0.key != "writer" }
      return .data(["writer": accounts[i].id, "expiresAt": "2026-09-22T10:00:00.000Z"])

    case ("DELETE", "/auth/writer/token"):
      if let i = (body["writer"] as? Int).flatMap(index) { accounts[i].claim = nil }
      return .data([:])

    case ("PUT", "/auth/chapter-keys"):
      guard let a = caller(r), let g = body["chapter"] as? Int else { return .error(401, info: "Sign in.") }
      if groupKeys[g] != nil { return .error(409, info: "This group already has a key.") }
      if a.role == "admin" { return .error(403, info: "A superadmin cannot create a chapter's key: whoever makes a key knows it.") }
      groupKeys[g] = (body["publicKey"] as! String, 1)
      memberKeys[g, default: [:]][a.id] = body["wrappedOrgPrivateKey"] as? String
      if !predatesGroupRoles {
        tellAdmins(of: g, except: a.id, "group.key", detail: ["action": "set"])
        if owners[g] == nil { owners[g] = a.id; tellAdmins(of: g, except: a.id, "group.owner", detail: ["owner": a.id, "previous": NSNull(), "by": "first key"]) }
      }
      return .data([:])

    case ("GET", "/auth/member-keys"):
      let g = r.query["chapter"].flatMap(Int.init) ?? 0
      if inactiveGroups.contains(g) { return .error(403, info: "Your group is not active.") }
      var answer: [String: Any] = ["chapter": g, "members": admins(of: g).map { m -> [String: Any] in
        ["id": m.id, "username": m.username, "name": m.name ?? NSNull(), "publicKey": m.keys["publicKey"] ?? NSNull(), "holdsGroupKey": memberKeys[g]?[m.id] != nil]
      }]
      if !predatesGroupRoles {
        answer["owner"] = orNull(owners[g])
        answer["waiting"] = admins(of: g).filter { $0.keys["publicKey"] != nil && memberKeys[g]?[$0.id] == nil }.map(\.id)
      }
      return .data(answer)

    case ("PUT", "/auth/chapter-owner"):
      if predatesGroupRoles { return .error(404, info: "Cannot PUT /auth/chapter-owner") }
      guard let a = caller(r), let g = body["chapter"] as? Int, let target = body["user"] as? Int else { return .error(401, info: "Sign in.") }
      guard a.role == "admin" || owners[g] == a.id else { return .error(403, info: "Only the group-owner admin, or a superadmin, can move ownership.") }
      guard admins(of: g).contains(where: { $0.id == target }) else { return .error(400, extra: ["errors": ["user must be a group admin of this chapter."]]) }
      let previous = owners[g]
      owners[g] = target
      for admin in admins(of: g) { tellLocked(admin.id, "group.owner", chat: nil, message: nil, detail: ["owner": target, "previous": orNull(previous), "by": a.role == "admin" ? "superadmin" : "owner"]) }
      return .data(["chapter": g, "owner": target, "previous": orNull(previous), "holdsGroupKey": memberKeys[g]?[target] != nil])

    case ("PUT", "/auth/member-key"):
      if inactiveGroups.contains(body["chapter"] as? Int ?? 0) { return .error(403, info: "Your group is not active.") }
      if !predatesGroupRoles, let a = caller(r), let g = body["chapter"] as? Int, owners[g] != a.id { return .error(403, info: Self.ownerOnly) }
      if let sealedFor = body["keyVersion"] as? Int, sealedFor != groupKeys[body["chapter"] as? Int ?? 0]?.version {
        return .error(409, info: "Error saving.", extra: ["name": "KeyVersionError", "error": "That group rotated its key."])
      }
      memberKeys[body["chapter"] as! Int, default: [:]][body["user"] as! Int] = body["wrappedOrgPrivateKey"] as? String
      if !predatesGroupRoles, let a = caller(r) { tellAdmins(of: body["chapter"] as! Int, except: a.id, "group.key", detail: ["action": "handed", "member": body["user"] as! Int]) }
      return .data([:])

    case ("DELETE", "/auth/member-key"):
      let g = body["chapter"] as! Int, target = body["user"] as! Int
      if !predatesGroupRoles, let a = caller(r), owners[g] != a.id { return .error(403, info: Self.ownerOnly) }
      if (memberKeys[g] ?? [:]).count <= 1 { return .error(409, info: "The last holder cannot be removed; rotate the key instead.") }
      memberKeys[g]?[target] = nil
      if !predatesGroupRoles, let a = caller(r) { tellAdmins(of: g, except: a.id, "group.key", detail: ["action": "removed", "member": target]) }
      return .data([:])

    case ("GET", "/auth/notifications"):
      guard let a = caller(r) else { return .error(401, info: "Sign in.") }
      let all = notifications[a.id] ?? []
      let unread = all.filter { $0["readAt"] is NSNull }
      var rows = r.query["unread"] == "true" ? unread : all
      if let since = r.query["since"].flatMap(Int.init) { rows = rows.filter { ($0["id"] as? Int ?? 0) > since } }
      return .data(rows, extra: ["total": rows.count, "page": 1, "page_size": 10, "unread": unread.count])

    case ("PUT", "/auth/notifications/read"):
      guard let a = caller(r) else { return .error(401, info: "Sign in.") }
      let before = (notifications[a.id] ?? []).filter { $0["readAt"] is NSNull }.count
      notifications[a.id] = (notifications[a.id] ?? []).map { var n = $0; n["readAt"] = "2026-09-19T11:00:00.000Z"; return n }
      return .data(["marked": before, "unread": 0])

    case ("POST", "/messaging/message"):
      guard let a = caller(r) else { return .error(401, info: "Sign in.") }
      for e in body["envelopes"] as? [[String: Any]] ?? [] where e["readerType"] as? String == "chapter" {
        if e["keyVersion"] as? Int != groupKeys[e["readerId"] as? Int ?? 0]?.version { return .error(409, info: "Error sending.", extra: ["name": "KeyVersionError", "error": "That group rotated its key."]) }
      }
      // An envelope for a writer without a public key is a 400 (PR #95).
      for e in body["envelopes"] as? [[String: Any]] ?? [] where e["readerType"] as? String == "user" {
        if accounts.first(where: { $0.id == e["readerId"] as? Int })?.keys["publicKey"] == nil { return .error(400, extra: ["errors": ["That writer has no public key."]]) }
      }
      if let replaced = body["resendOf"] as? Int {
        // One of the same writer's returned letters to the same prisoner, or a 400 (PR #105).
        let original = messages.first { $0["id"] as? Int == replaced }
        guard let original, original["status"] as? String == "returned", original["user"] as? Int == (body["user"] as? Int ?? a.id), original["prisoner"] as? Int == body["prisoner"] as? Int else {
          return .error(400, extra: ["errors": ["resendOf must be one of this writer's returned letters to the same prisoner."]])
        }
      }
      var m = body
      m["heldReason"] = nil; m["returnReason"] = nil // read-only: nobody sets a hold by writing a letter
      m["id"] = id(); m["chat"] = 7; m["status"] = body["sender"] as? String == "prisoner" ? "received" : "queued"
      m["user"] = body["user"] ?? a.id; m["createdAt"] = "2026-09-19T10:00:00.000Z"; m["keep"] = false
      messages.append(m)
      return .data(visible(m, to: a))

    case ("GET", "/chat/chats"):
      guard let a = caller(r) else { return .error(401, info: "Sign in.") }
      let mine = messages.filter { $0["user"] as? Int == a.id }
      let chats = Set(mine.compactMap { $0["prisoner"] as? Int }).sorted().map { ["id": $0, "prisoner": $0] as [String: Any] }
      let size = Int(r.query["page_size"] ?? "20") ?? 20
      return .data(Array(chats.prefix(size)), extra: ["total": chats.count, "page": 1, "page_size": size])

    case ("GET", "/chat/chat"):
      // Like the real one: a conversation's letters come with their columns, and without `status_history` or `resent_as`.
      guard let a = caller(r), let pid = r.query["id"].flatMap(Int.init) else { return .error(401, info: "Sign in.") }
      let letters = messages.filter { $0["prisoner"] as? Int == pid && $0["user"] as? Int == a.id }.map { m in visible(m, to: a).filter { $0.key != "status_history" && $0.key != "resent_as" } }
      return .data(["id": pid, "prisoner": pid, "messages": letters])

    case ("GET", "/messaging/message"):
      guard let a = caller(r), let m = messages.first(where: { $0["id"] as? Int == r.query["id"].flatMap(Int.init) }) else { return .error(404, info: "No such letter.") }
      return .data(visible(m, to: a))

    case ("DELETE", "/messaging/message"):
      messages.removeAll { $0["id"] as? Int == body["id"] as? Int }
      return .data([:])

    case ("PUT", "/messaging/message"):
      guard let i = messages.firstIndex(where: { $0["id"] as? Int == body["id"] as? Int }) else { return .error(404, info: "No such letter.") }
      // Nobody sets or clears a hold by editing; choosing who mails it answers a choose_relay hold (PR #106).
      messages[i].merge(body.filter { $0.key != "heldReason" && $0.key != "returnReason" }) { $1 }
      if body["relayChapter"] is Int, messages[i]["heldReason"] as? String == "choose_relay" { messages[i]["heldReason"] = nil }
      for k in ["relayNoteCiphertext", "relayNoteNonce"] where body[k] == nil && body["ciphertext"] != nil { messages[i][k] = nil }
      return .data([:])

    case ("GET", "/messaging/messages"):
      guard let a = caller(r) else { return .error(401, info: "Sign in.") }
      let rows = messages.filter { m in
        guard m["relayChapter"] as? Int == r.query["relayChapter"].flatMap(Int.init) else { return false }
        if let status = r.query["status"], m["status"] as? String != status { return false }
        if !predatesHeldLetters, let held = r.query["held"], (m["heldReason"] is String) != (held == "true") { return false }
        return true
      }
      let full = r.query["full"] == "true" && !predatesLetterNights
      return .data(rows.map { m -> [String: Any] in
        var row = visible(m, to: a)
        if full, let pid = m["prisoner"] as? Int { row["prisoner_details"] = prisonerJSON(pid) }
        return row
      }, extra: ["total": rows.count, "page": 1, "page_size": 20])

    case ("PUT", "/messaging/status/batch"):
      if predatesLetterNights { return .error(404, info: "Cannot PUT /messaging/status/batch") }
      guard caller(r) != nil, let ids = body["ids"] as? [Int], let to = body["status"] as? String else { return .error(400, extra: ["errors": ["ids must be a list of letter ids."]]) }
      let order = ["queued", "printed", "mailed", "returned"]
      // All or none: look at every letter before touching one.
      for id in ids {
        guard let m = messages.first(where: { $0["id"] as? Int == id }) else { return .error(404, info: "Error updating letter status.", extra: ["error": "Message \(id) not found"]) }
        let from = m["status"] as? String ?? ""
        guard let f = order.firstIndex(of: from), let t = order.firstIndex(of: to), t == f + 1 else {
          return .error(409, info: "Error updating letter status.", extra: ["name": "LetterStatusError", "error": "Letter \(id): a \(from) letter cannot move to \(to)."])
        }
        if m["heldReason"] is String { return .error(409, info: "Error updating letter status.", extra: ["name": "LetterHeldError", "error": "Letter \(id) is held."]) }
      }
      var byWriter: [Int: [Int]] = [:]
      for i in messages.indices where ids.contains(messages[i]["id"] as? Int ?? -1) {
        messages[i]["status"] = to
        if to == "mailed", let g = messages[i]["relayChapter"] as? Int { lettersCounted[g, default: 0] += 1 }
        byWriter[messages[i]["user"] as? Int ?? 0, default: []].append(messages[i]["id"] as? Int ?? 0)
      }
      // One feed entry per writer, however many of their letters moved (PR #111).
      for (writer, moved) in byWriter {
        if moved.count == 1 { tellLocked(writer, "letter.status", chat: 7, message: moved[0], detail: ["status": to]) }
        else { tellLocked(writer, "letter.status", chat: 7, message: nil, detail: ["status": to, "count": moved.count, "messages": moved]) }
      }
      return .data(["status": to, "count": ids.count, "ids": ids])

    case ("GET", "/chapter/chapter"):
      let g = r.query["id"].flatMap(Int.init) ?? 0
      var group: [String: Any] = ["id": g, "name": "Test Chapter", "accountStatus": inactiveGroups.contains(g) ? "pending" : "active"]
      if !predatesGroupNumbers {
        let total = (lettersSentBefore[g] ?? 0) + (lettersCounted[g] ?? 0)
        group["lettersSent"] = total >= 20 ? String(total) : NSNull()
        group["averageTimeDays"] = total >= 20 ? 6 : NSNull()
        if let a = caller(r), a.chapterId == g { group["lettersSentBefore"] = lettersSentBefore[g] ?? 0; group["lettersCounted"] = lettersCounted[g] ?? 0 }
      }
      return .data(group)

    case ("PUT", "/chapter/chapter"):
      guard let a = caller(r), let g = body["id"] as? Int, a.chapterId == g else { return .error(403, info: "Not your group.") }
      // Counted by the server, not typed: sending them changes nothing.
      if let before = body["lettersSentBefore"] as? Int { lettersSentBefore[g] = before }
      return .data([:])

    case ("PUT", "/messaging/status"):
      guard let a = caller(r), let i = messages.firstIndex(where: { $0["id"] as? Int == body["id"] as? Int }) else { return .error(404, info: "No such letter.") }
      let order = ["queued", "printed", "mailed", "returned"], from = messages[i]["status"] as? String ?? "", to = body["status"] as? String ?? ""
      let reason = body["reason"] as? String, note = body["note"] as? String
      if to == "returned" {
        guard let reason, ["refused", "rule_violation", "transferred", "released", "bad_address", "unknown"].contains(reason) else { return .error(400, extra: ["errors": ["A returned letter needs a reason."]]) }
        if (note ?? "").count > 200 { return .error(400, extra: ["errors": ["note can be at most 200 characters."]]) }
      } else if reason != nil || note != nil {
        return .error(400, extra: ["errors": ["reason and note only go with the status returned."]])
      }
      guard let f = order.firstIndex(of: from), let t = order.firstIndex(of: to), t == f + 1 else {
        return .error(409, info: "Error updating letter status.", extra: ["name": "LetterStatusError", "error": "A \(from) letter cannot move to \(to)."])
      }
      if let held = messages[i]["heldReason"] as? String, body["release"] as? Bool != true {
        return .error(409, info: "Error updating letter status.", extra: ["name": "LetterHeldError", "error": "This letter is held (\(held)). Send release: true to go ahead with it anyway."])
      }
      if to == "mailed", let g = messages[i]["relayChapter"] as? Int { lettersCounted[g, default: 0] += 1 }
      messages[i]["status"] = to; messages[i]["heldReason"] = nil; messages[i]["returnReason"] = to == "returned" ? reason : nil
      var history = messages[i]["status_history"] as? [[String: Any]] ?? []
      history.append(["fromStatus": from, "toStatus": to, "changedBy": a.id, "createdAt": "2026-09-20T10:00:00.000Z", "reason": (to == "returned" ? reason : nil) ?? NSNull(), "note": note ?? NSNull()])
      messages[i]["status_history"] = history
      if let writer = messages[i]["user"] as? Int {
        var detail: [String: Any] = ["status": to]
        if to == "returned", let reason { detail["reason"] = reason }
        tellLocked(writer, "letter.status", chat: messages[i]["chat"] as? Int, message: messages[i]["id"] as? Int, detail: detail)
      }
      return .data(visible(messages[i], to: a))

    case ("GET", "/messaging/envelopes/missing"):
      guard let a = caller(r), let g = a.chapterId, mode == "e2e" else { return .error(403, info: "Group members, end-to-end mode.") }
      let rows: [[String: Any]] = messages.compactMap { m in
        let envelopes = m["envelopes"] as? [[String: Any]] ?? []
        guard let groups = envelopes.first(where: { $0["readerType"] as? String == "chapter" && $0["readerId"] as? Int == g }),
              let writer = accounts.first(where: { $0.id == m["user"] as? Int }), let publicKey = writer.keys["publicKey"],
              !envelopes.contains(where: { $0["readerType"] as? String == "user" && $0["readerId"] as? Int == writer.id }) else { return nil }
        return ["message": m["id"]!, "chat": m["chat"]!, "readerType": "user", "readerId": writer.id, "publicKey": publicKey, "wrappedKey": groups["wrappedKey"]!, "keyVersion": groups["keyVersion"] ?? NSNull()]
      }
      return .data(rows)

    case ("POST", "/messaging/envelope"):
      if mode != "e2e" { return .error(409, info: "Server mode has no envelopes to add.") }
      guard let i = messages.firstIndex(where: { $0["id"] as? Int == body["message"] as? Int }) else { return .error(404, info: "No such letter.") }
      messages[i]["envelopes"] = (messages[i]["envelopes"] as? [[String: Any]] ?? []) + [body.filter { $0.key != "message" }]
      return .data([:])

    case ("POST", "/messaging/attachment"):
      let parts = Multipart(r)
      let new = id()
      let meta: [String: Any] = ["id": new, "message": Int(parts.fields["message"] ?? "") ?? 0, "originalName": parts.filename ?? "file", "mimeType": parts.fileType ?? "application/octet-stream", "size": parts.file.count, "nonce": parts.fields["nonce"] ?? NSNull()]
      attachments[new] = (meta, parts.file)
      return .data(meta)

    case ("GET", "/messaging/attachment"):
      guard let a = attachments[r.query["id"].flatMap(Int.init) ?? 0] else { return .error(404, info: "No such file.") }
      return Stubbed(body: a.bytes)

    case ("GET", "/prisoner/prisoner"):
      return .data(prisonerJSON(r.query["id"].flatMap(Int.init) ?? 0))

    case ("GET", "/prison/prison"):
      return .data(["id": 1, "prisonName": "Test Prison", "routing": "direct", "relay_groups": [["id": 1, "name": "Test Chapter", "accountStatus": "active"], ["id": 2, "name": "Partner Chapter", "accountStatus": "active"], ["id": 3, "name": "Suspended Chapter", "accountStatus": "suspended"]]])

    case ("GET", "/prison/mail-rules"):
      return .data(["categories": [], "rules": []])

    default:
      return .error(404, info: "The fake API has no \(r.method) \(r.path).")
    }
  }
}

/// Just enough multipart parsing to check what an upload carried.
struct Multipart {
  var fields: [String: String] = [:]
  var file = Data()
  var filename: String?
  var fileType: String?

  init(_ r: Recorded) {
    guard let type = r.headers["Content-Type"], let boundary = type.components(separatedBy: "boundary=").last else { return }
    let delimiter = Data("--\(boundary)".utf8), blank = Data("\r\n\r\n".utf8)
    var parts: [Data] = []
    var rest = r.body[...]
    while let range = rest.range(of: delimiter) {
      parts.append(Data(rest[rest.startIndex..<range.lowerBound]))
      rest = rest[range.upperBound...]
    }
    for part in parts {
      guard let split = part.range(of: blank) else { continue }
      let head = String(decoding: part[part.startIndex..<split.lowerBound], as: UTF8.self)
      let content = Data(part[split.upperBound..<part.endIndex].dropLast(2)) // the CRLF before the next delimiter
      guard let name = head.components(separatedBy: "name=\"").dropFirst().first?.components(separatedBy: "\"").first else { continue }
      if head.contains("filename=\"") {
        file = content
        filename = head.components(separatedBy: "filename=\"").last?.components(separatedBy: "\"").first
        fileType = head.components(separatedBy: "Content-Type: ").last?.trimmingCharacters(in: .whitespacesAndNewlines)
      } else {
        fields[name] = String(decoding: content, as: UTF8.self)
      }
    }
  }
}
