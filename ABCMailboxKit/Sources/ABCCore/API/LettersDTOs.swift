import Foundation

// `/chat` and `/messaging`: threads, letters, attachments. Everything here is
// scoped by the token: a writer only ever sees their own threads.

struct IdBody: Encodable {
  let id: Int
}

struct SendMessageRequest: Encodable {
  /// Server mode. In end-to-end mode this stays nil and the four cipher fields plus `envelopes` are sent.
  var messageText: String?
  let prisoner: Int
  /// Required by the API: "user", or "prisoner" for a recorded reply.
  let sender: String
  /// Group accounts only: a managed writer to send as (omit for the group's anonymous writer),
  /// or, with `sender = "prisoner"`, the writer whose thread a reply belongs to. Ignored for writers.
  let user: Int?
  /// Omitted (not null) when unset, so the server resolves the relay group itself.
  let relayChapter: Int?
  /// The writer's returned letter to the same prisoner that this one replaces (API PR #105). Omitted when nil.
  var resendOf: Int?
  var relayNote: String?
  var ciphertext: String?
  var nonce: String?
  var relayNoteCiphertext: String?
  var relayNoteNonce: String?
  var envelopes: [EnvelopeDTO]?
}

/// A letter's content key sealed to one reader. Group readers name the `keyVersion` it was sealed to.
struct EnvelopeDTO: Codable, Equatable {
  let readerType: String
  let readerId: Int
  let wrappedKey: String
  let keyVersion: Int?
}

/// Answers a `choose_relay` hold (API PR #106): nothing about the letter changes except who mails it.
struct ChooseRelayRequest: Encodable {
  let id: Int
  let relayChapter: Int
}

struct UpdateMessageRequest: Encodable {
  let id: Int
  var messageText: String?
  var relayNote: String?
  var relayChapter: Int?
  var ciphertext: String?
  var nonce: String?
  var relayNoteCiphertext: String?
  var relayNoteNonce: String?
}

struct ChatDTO: Decodable {
  let id: Int
  let prisoner: Int
  let updatedAt: String?
  let lastMessageAt: String?
  let lastMessage: LastMessageDTO?
  let messages: [MessageDTO]?
  let userDetails: UserDTO?
  let prisonerDetails: PrisonerDTO?
  /// API PR #117: how many of the thread's letters are held, and the distinct reasons.
  let heldCount: Int?
  let heldReasons: [String]?

  private enum CodingKeys: String, CodingKey {
    case id, prisoner, updatedAt, lastMessageAt, messages, heldCount, heldReasons
    case lastMessage = "last_message", userDetails = "user_details", prisonerDetails = "prisoner_details"
  }
}

struct LastMessageDTO: Decodable {
  let id: Int
  let sender: String
  let messageText: String?
  let status: String?
  let createdAt: String?
  let ciphertext: String?
  let nonce: String?
  let envelopes: [EnvelopeDTO]?
}

struct MessageDTO: Decodable {
  let id: Int
  let chat: Int?
  let sender: String
  let prisoner: Int
  let user: Int?
  let status: String?
  let relayChapter: Int?
  let relayNote: String?
  let messageText: String?
  let keep: Bool?
  let statusChangedAt: String?
  let createdAt: String?
  let statusHistory: [StatusHistoryDTO]?
  let attachments: [AttachmentDTO]?
  let relayGroup: RelayGroupDTO?
  // End-to-end mode: `messageText` is null and these carry the letter; `envelopes` is filtered to the caller.
  let ciphertext: String?
  let nonce: String?
  let relayNoteCiphertext: String?
  let relayNoteNonce: String?
  let envelopes: [EnvelopeDTO]?
  let returnReason: String?
  /// API PR #117: the return's note on the letter itself, so a conversation need not read every returned letter's history.
  let returnNote: String?
  let heldReason: String?
  let resendOf: Int?
  let resentAs: [ResentAsDTO]?
  /// With `full=true` since API PR #111: who the letter goes to, with the facility, its address and its rules.
  let prisonerDetails: PrisonerDTO?

  private enum CodingKeys: String, CodingKey {
    case id, chat, sender, prisoner, user, status, relayChapter, relayNote, messageText, keep, statusChangedAt, createdAt, attachments
    case returnReason, returnNote, heldReason, resendOf
    case resentAs = "resent_as", prisonerDetails = "prisoner_details"
    case ciphertext, nonce, relayNoteCiphertext, relayNoteNonce, envelopes
    case statusHistory = "status_history", relayGroup = "relay_group"
  }
}

struct ResentAsDTO: Decodable {
  let id: Int
  let status: String?
  let createdAt: String?
}

struct RelayGroupDTO: Decodable {
  let id: Int
  let name: String
}

struct StatusHistoryDTO: Decodable {
  let fromStatus: String?
  let toStatus: String
  let changedBy: Int?
  let createdAt: String?
  let reason: String?
  let note: String?
}

struct AttachmentDTO: Decodable {
  let id: Int
  let message: Int
  let originalName: String
  let mimeType: String
  let size: Int
  let nonce: String?
}

struct RetentionDTO: Decodable {
  let effectiveDays: Int?
}
