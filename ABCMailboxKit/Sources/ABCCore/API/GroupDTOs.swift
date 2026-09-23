import ABCCrypto
import Foundation

// What a support group member does: the print queue, status moves, and the
// writers the group looks after. Every call needs a `chapter` account whose
// group is active; otherwise the API answers 403 with a sentence that says
// which condition failed, and the app shows that sentence as is.

struct StatusRequest: Encodable {
  let id: Int
  let status: String
  /// With `returned` only; the API refuses them on any other move.
  var reason: String?
  var note: String?
  /// Printing a held letter on purpose (API PR #106). Omitted otherwise.
  var release: Bool?
}

struct WriterRef: Encodable {
  let writer: Int
}

struct AddWriterRequest: Encodable {
  let name: String
  let email: String?
  let managerNote: String?
  // End-to-end only: the keypair the group made for the writer, private half sealed to the group key of that version.
  var publicKey: String?
  var orgWrappedPrivateKey: String?
  var orgKeyVersion: Int?
}

/// Server mode: send `{writer}` and the token comes back once. End-to-end: the
/// token is made on the device and only its hash and the key wrapped under it
/// are sent, so the answer carries just `expiresAt`. Regenerating replaces the previous one.
struct IssueTokenRequest: Encodable {
  let writer: Int
  var tokenHash: String?
  var claimWrappedPrivateKey: String?
  var claimSalt: String?
  var claimKdfParams: KdfParams?
}

struct GroupKeyRequest: Encodable {
  let chapter: Int
  let publicKey: String
  let wrappedOrgPrivateKey: String
}

/// `keyVersion`: the version of the group key that was sealed. If the group rotated meanwhile the server answers
/// 409 `KeyVersionError`, and a stale key is not handed on.
struct MemberKeyRequest: Encodable {
  let chapter: Int
  let user: Int
  let wrappedOrgPrivateKey: String
  var keyVersion: Int?
}

/// Several letters moved together, all or none (API PR #111). `reason` and `note` go with `returned` only.
struct BatchStatusRequest: Encodable {
  let ids: [Int]
  let status: String
}

struct BatchStatusDTO: Decodable {
  let count: Int?
}

/// Only the id and the one field a person types (API PR #112): the rest of a group's numbers are the server's.
struct LettersSentBeforeRequest: Encodable {
  let id: Int
  let lettersSentBefore: Int
}

struct MemberRef: Encodable {
  let chapter: Int
  let user: Int
}

struct AddEnvelopeRequest: Encodable {
  let message: Int
  let readerType: String
  let readerId: Int
  let wrappedKey: String
  let keyVersion: Int?
}

struct MemberKeysDTO: Decodable {
  let members: [MemberDTO]?
  /// API PR #115: the chapter's group-owner admin, and the group admins with keys of their own who are still to be handed the chapter's.
  let owner: Int?
  let waiting: [Int]?
}

/// `PUT /auth/chapter-owner`: make another group admin of the chapter its group-owner admin (API PR #115).
struct OwnerRequest: Encodable {
  let chapter: Int
  let user: Int
}

struct OwnerDTO: Decodable {
  let chapter: Int?
  let owner: Int?
  let previous: Int?
  let holdsGroupKey: Bool?
}

struct MemberDTO: Decodable {
  let id: Int
  let username: String?
  let name: String?
  let publicKey: String?
  let holdsGroupKey: Bool?
}

struct WriterDTO: Decodable {
  let id: Int
  let name: String?
  let username: String?
  let email: String?
  let managerNote: String?
  /// Set on the group's shared anonymous account, which is not a person and cannot be handed off.
  let anonymousForChapter: Int?
  let publicKey: String?
  /// End-to-end only: the writer's private key sealed to the group, while the account is unclaimed.
  let orgWrappedPrivateKey: String?
  let claimToken: ClaimTokenStateDTO?
}

struct ClaimTokenStateDTO: Decodable {
  let expiresAt: String?
}

struct IssuedTokenDTO: Decodable {
  let token: String?
  let expiresAt: String?
}

/// End-to-end, API PR #95: a letter this group can open whose writer had no key when it was recorded
/// (a reply for someone who had not signed in since the switch) and has one now. `wrappedKey` is the
/// group's own envelope; the member's phone opens it, seals the content key to `publicKey`, and posts it.
struct MissingEnvelopeDTO: Decodable {
  let message: Int
  let readerType: String?
  let readerId: Int
  let publicKey: String?
  let wrappedKey: String?
}
