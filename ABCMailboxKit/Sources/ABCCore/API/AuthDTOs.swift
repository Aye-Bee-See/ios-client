import ABCCrypto
import Foundation

// `/auth`: accounts and sessions. DTOs mirror the JSON exactly; mapping to the
// models the screens use happens in the repositories.

struct LoginRequest: Encodable {
  let username: String
  let password: String
}

/// Step one of signing in (API PR #114): which scheme the account uses and, for the split scheme, the salt and
/// recipe the device derives its keys with. Public. For an unknown name the answer is a made-up but stable salt,
/// so it never says whether an account exists. Absent from an older API (404): then everything is `plain`.
struct LoginParamsDTO: Decodable {
  let scheme: String?
  let kdfSalt: String?
  let kdfParams: JSONValue?
  var isSplit: Bool { scheme == "split" && kdfSalt != nil && kdfParams != nil && kdfParams != .null }
}

struct LogoutRequest: Encodable {
  let everywhere: Bool
}

struct TokenDTO: Decodable {
  let token: String
  /// Milliseconds since the epoch.
  let expires: Double
}

struct LoginData: Decodable {
  let user: UserDTO
  let token: TokenDTO
  /// End-to-end mode only. An account with no keys yet gets an object of nulls.
  let keys: KeyBundleDTO?
}

/// The user record as the API returns it. Wrapped keys and passwords never appear.
struct UserDTO: Decodable {
  let id: Int
  let username: String
  let email: String?
  let name: String?
  let role: String
  let chapterId: Int?
  /// The chapter whose invite code made the account (API PR #116). Read, never sent.
  let sponsoredBy: Int?
  let managedBy: Int?
  let anonymousForChapter: Int?
  let publicKey: String?
}

struct KeyBundleDTO: Decodable {
  let publicKey: String?
  let wrappedPrivateKey: String?
  let kdfSalt: String?
  /// Kept as raw JSON: it is parsed (and validated) only when a key is actually unwrapped.
  let kdfParams: JSONValue?
  let orgKey: OrgKeyDTO?

  /// All four present. An account without them gets a keypair at its next sign-in.
  var material: (publicKey: String, wrapped: String, salt: String, params: JSONValue)? {
    guard let publicKey, let wrappedPrivateKey, let kdfSalt, let kdfParams, kdfParams != .null else { return nil }
    return (publicKey, wrappedPrivateKey, kdfSalt, kdfParams)
  }
}

struct OrgKeyDTO: Decodable {
  let chapterId: Int
  let chapterPublicKey: String?
  let wrappedOrgPrivateKey: String?
  let keyVersion: Int?
  /// API PR #115: who owns the chapter's key, and whether that is the caller.
  let owner: Int?
  let isOwner: Bool?
}

struct NamedRef: Decodable {
  let id: Int
  let name: String?
}

struct ClaimInfoDTO: Decodable {
  let writer: NamedRef
  let chapter: NamedRef?
  let expiresAt: String?
  // End-to-end mode: the writer's keypair, private half wrapped under the claim token.
  let publicKey: String?
  let claimWrappedPrivateKey: String?
  let claimSalt: String?
  let claimKdfParams: JSONValue?

  var material: (publicKey: String, wrapped: String, salt: String, params: JSONValue)? {
    guard let publicKey, let claimWrappedPrivateKey, let claimSalt, let claimKdfParams, claimKdfParams != .null else { return nil }
    return (publicKey, claimWrappedPrivateKey, claimSalt, claimKdfParams)
  }
}

/// `GET /auth/join?code=`: who is inviting, and until when (API PR #116).
struct JoinInfoDTO: Decodable {
  let chapter: NamedRef?
  let expiresAt: String?
}

/// `POST /auth/join`: the same password and key fields as a claim, with the code instead of a token.
struct JoinRequest: Encodable {
  let code: String
  let username: String
  var password: String
  let email: String?
  let name: String?
  var penName: String?
  var authScheme: String?
  var publicKey: String?
  var wrappedPrivateKey: String?
  var kdfSalt: String?
  var kdfParams: KdfParams?
  var recoveryWrappedPrivateKey: String?
  var recoverySalt: String?
  var recoveryKdfParams: KdfParams?
}

/// A request that makes an account with keys made on this phone: joining with an invite code, or accepting an
/// invitation. The password and key fields are filled the same way for both (`SessionRepository.fillNewAccount`).
protocol NewAccountRequest {
  var password: String { get set }
  var authScheme: String? { get set }
  var publicKey: String? { get set }
  var wrappedPrivateKey: String? { get set }
  var kdfSalt: String? { get set }
  var kdfParams: KdfParams? { get set }
  var recoveryWrappedPrivateKey: String? { get set }
  var recoverySalt: String? { get set }
  var recoveryKdfParams: KdfParams? { get set }
}

extension JoinRequest: NewAccountRequest {}

/// `GET /invitation/invitation?token=`.
struct InvitationInfoDTO: Decodable {
  let kind: String?
  let inviteeName: String?
  let chapter: NamedRef?
  let expiresAt: String?
  let activation: String?
  let groupFields: [String]?
}

/// `POST /invitation/accept`: the account fields of a join, the token, and for a `group` invitation the new group.
struct AcceptInvitationRequest: Encodable, NewAccountRequest {
  let token: String
  let username: String
  var password: String
  let email: String?
  let name: String?
  var penName: String?
  var group: GroupProfileDTO?
  var authScheme: String?
  var publicKey: String?
  var wrappedPrivateKey: String?
  var kdfSalt: String?
  var kdfParams: KdfParams?
  var recoveryWrappedPrivateKey: String?
  var recoverySalt: String?
  var recoveryKdfParams: KdfParams?
}

/// The new group's profile, limited to the invitation's `groupFields`: a field it does not list is left out,
/// because the server refuses the whole acceptance over one it does not allow.
struct GroupProfileDTO: Encodable, Equatable {
  struct Location: Encodable, Equatable { let city: String }
  var name: String?
  var location: Location?
  var country: String?
  var about: String?
  var website: String?
  var email: String?

  init(_ p: NewGroupProfile, allowed: Set<String>) {
    func field(_ key: String, _ value: String) -> String? { allowed.contains(key) ? value.trimmed.nonBlank : nil }
    name = field("name", p.name)
    location = field("location", p.city).map(Location.init(city:))
    country = field("country", p.country)
    about = field("about", p.about)
    website = field("website", p.website)
    email = field("email", p.email)
  }
}

struct AcceptedInvitationDTO: Decodable {
  struct Group: Decodable { let id: Int; let name: String?; let accountStatus: String? }
  let user: UserDTO?
  let chapter: Group?
  let activation: String?
}

/// `GET /auth/pen-name-available?name=`.
struct PenNameCheckDTO: Decodable {
  let available: Bool?
  let name: String?
  let reason: String?
  let twoParts: Bool?
}

/// `GET /auth/pen-name`: the names, and the limits from API #127 (absent from an older API).
struct PenNamesDTO: Decodable {
  struct Row: Decodable { let name: String; let current: Bool?; let since: String? }
  let penName: String?
  let names: [Row]?
  let changeAllowedAt: String?
  let newNamesLeft: Int?
  let newNamesWindowEnds: String?
  let cooldownDays: Int?
  let newPerYear: Int?
}

struct JoinedDTO: Decodable {
  let user: UserDTO?
  let chapter: NamedRef?
}

struct ClaimRequest: Encodable {
  let token: String
  let username: String
  var password: String
  let email: String?
  /// `"split"`: `password` is the auth key, derived with `kdfSalt`/`kdfParams` (API PR #114). Absent means plain.
  var authScheme: String?
  // End-to-end mode: the same private key, re-wrapped under the new password and a new recovery code.
  var wrappedPrivateKey: String?
  var kdfSalt: String?
  var kdfParams: KdfParams?
  var recoveryWrappedPrivateKey: String?
  var recoverySalt: String?
  var recoveryKdfParams: KdfParams?
}

struct UpdateUserRequest: Encodable {
  let id: Int
  /// A pen name change (API #127 limits it: once every 90 days, two new names a year).
  var penName: String?
  var password: String?
  /// `"split"`: `password` is the auth key, derived with `kdfSalt`/`kdfParams` (API PR #114). Absent means plain.
  var authScheme: String?
  // End-to-end mode: a password change must carry the private key re-wrapped under the new password.
  var wrappedPrivateKey: String?
  var kdfSalt: String?
  var kdfParams: KdfParams?
  // End-to-end mode, managing group only, once: the keypair it made for an unclaimed writer who has none.
  var publicKey: String?
  var orgWrappedPrivateKey: String?
  var orgKeyVersion: Int?
}

struct UpdateUserData: Decodable {
  let token: TokenDTO?
}

struct KeyFieldsRequest: Encodable {
  let publicKey: String?
  let wrappedPrivateKey: String
  let kdfSalt: String
  let kdfParams: KdfParams
  let recoveryWrappedPrivateKey: String
  let recoverySalt: String
  let recoveryKdfParams: KdfParams

  init(_ fields: AccountKeyFields) {
    publicKey = fields.publicKey
    wrappedPrivateKey = fields.password.wrapped
    kdfSalt = fields.password.salt
    kdfParams = fields.password.params
    recoveryWrappedPrivateKey = fields.recovery.wrapped
    recoverySalt = fields.recovery.salt
    recoveryKdfParams = fields.recovery.params
  }
}

struct PublicKeyDTO: Decodable {
  let publicKey: String?
  let keyVersion: Int?
}

struct RecoverStartDTO: Decodable {
  let publicKey: String
  let recoveryWrappedPrivateKey: String
  let recoverySalt: String
  let recoveryKdfParams: JSONValue
  let sealedChallenge: String
}

struct RecoverFinishRequest: Encodable {
  let username: String
  let challenge: String
  let password: String
  let wrappedPrivateKey: String
  let kdfSalt: String
  let kdfParams: KdfParams
  /// `"split"`: `password` is the auth key, derived with `kdfSalt`/`kdfParams` (API PR #114). Absent means plain.
  var authScheme: String?
}

struct HealthDTO: Decodable {
  let status: String?
  let encryptionMode: String?
}

/// `DELETE /auth/user` (API PR #104). For one's own account the current password is required, so that a
/// borrowed phone or a stolen token is not enough.
struct DeleteUserRequest: Encodable {
  let id: Int
  let password: String?
}

struct DeletedUserDTO: Decodable {
  let letters: Int?
  let replies: Int?
  let attachments: Int?
  let threads: Int?
}
