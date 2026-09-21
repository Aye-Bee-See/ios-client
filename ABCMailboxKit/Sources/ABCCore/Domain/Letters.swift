import Foundation

public enum LetterStatus: String, CaseIterable, Sendable {
  case queued, printed, mailed, received
  /// The post brought it back (API PR #105). From `mailed` only, and final.
  case returned
  case unknown = ""

  public var key: String { rawValue }

  public var label: String {
    switch self {
    case .queued: return "Queued"
    case .printed: return "Printed"
    case .mailed: return "Mailed"
    case .received: return "Received"
    case .returned: return "Returned"
    case .unknown: return "Unknown"
    }
  }

  public static func from(key: String?) -> LetterStatus { key.flatMap { $0.isEmpty ? nil : LetterStatus(rawValue: $0) } ?? .unknown }
}

/// Why the post brought a letter back. The API sends a code; the words are decided here.
public enum ReturnReason: String, CaseIterable, Identifiable, Sendable {
  case refused
  case ruleViolation = "rule_violation"
  case transferred, released
  case badAddress = "bad_address"
  case unknown

  public var id: String { rawValue }
  public var key: String { rawValue }

  /// A code this version has never heard of is still a return: it reads as "nothing says why".
  public static func from(key: String?) -> ReturnReason? { key.flatMap { $0.isEmpty ? nil : ReturnReason(rawValue: $0) ?? .unknown } }

  /// For the volunteer holding the envelope, choosing what happened.
  public var choice: String {
    switch self {
    case .refused: return "Refused, no rule named"
    case .ruleViolation: return "Broke a mail rule"
    case .transferred: return "Moved to another facility"
    case .released: return "No longer held there"
    case .badAddress: return "Undeliverable as addressed"
    case .unknown: return "Nothing says why"
    }
  }

  /// For the writer, as the end of "It came back: …".
  public var sentence: String {
    switch self {
    case .refused: return "the mail room refused it and named no rule."
    case .ruleViolation: return "the mail room says it broke one of the facility's mail rules."
    case .transferred: return "the mail room says they are held somewhere else now."
    case .released: return "the mail room says they are no longer held there."
    case .badAddress: return "it could not be delivered as addressed."
    case .unknown: return "nothing on the envelope says why."
    }
  }

  /// What the writer can do about it, said under the reason until the letter has been sent again. One for
  /// every reason, in the words the Android app uses.
  public var advice: String {
    switch self {
    case .refused: return "Look at the facility's mail rules before sending it again; the group that mailed it may know more."
    case .ruleViolation: return "Check the rules shown when you write, change what broke them, and send it again."
    case .transferred: return "Sent again, it goes to wherever the directory now says they are. If the directory still shows the old place, it may come back again: check their profile first."
    case .released: return "They may have been freed. Check their profile before sending anything to a prison again."
    case .badAddress: return "The address in the directory may be wrong. Your group can correct it; sent again after that, the letter goes to the new one."
    case .unknown: return "You can send it again as it is. If it comes back twice, ask the group that mailed it."
    }
  }

  /// The directory may be wrong about where this person is, so sending the same letter again may fail the same way.
  public var doubtsTheAddress: Bool { self == .transferred || self == .released || self == .badAddress }
}

/// Why a queued letter is waiting instead of being printed (API PR #106): the person it is for was
/// moved or freed after it was written. A hold is not a status; the letter stays `queued`.
public enum HeldReason: String, Sendable {
  /// Moved to a facility where the writer has to say who mails it.
  case chooseRelay = "choose_relay"
  /// Moved, end-to-end mode: sealed to a group that does not serve the new facility. Only the writer's device can seal it again.
  case resealNeeded = "reseal_needed"
  case prisonerFree = "prisoner_free"
  /// A reason this version has never heard of. The letter is held all the same.
  case other = ""

  public static func from(key: String?) -> HeldReason? { key.flatMap { $0.isEmpty ? nil : HeldReason(rawValue: $0) ?? .other } }
}

/// A letter sent in place of a returned one.
public struct Resend: Equatable, Identifiable, Sendable {
  public let id: Int
  public let status: LetterStatus
  public let createdAt: Date?
}

public struct Attachment: Equatable, Identifiable, Sendable {
  public let id: Int
  public let messageId: Int
  public let name: String
  public let mimeType: String
  public let size: Int
  /// End-to-end mode: the nonce the file was encrypted with. Nil means the bytes are plain.
  public let nonce: String?

  public var sizeLabel: String {
    if size >= 1_048_576 { return String(format: "%.1f MB", Double(size) / 1_048_576.0) }
    if size >= 1024 { return "\(size / 1024) KB" }
    return "\(size) B"
  }
}

public struct StatusChange: Equatable, Sendable {
  public let from: LetterStatus?
  public let to: LetterStatus
  public let at: Date?
  public let byUserId: Int?
  /// For a move to `returned`: why, and a few words from whoever handled the envelope.
  public var reason: ReturnReason? = nil
  public var note: String? = nil
}

public struct Letter: Equatable, Identifiable, Sendable {
  public let id: Int
  public let threadId: Int?
  public let prisonerId: Int?
  public let writerId: Int?
  public let fromPrisoner: Bool
  public let status: LetterStatus
  public var body: String
  public var relayNote: String?
  public let relayGroupId: Int?
  public let relayGroupName: String?
  public let keep: Bool
  public let createdAt: Date?
  public let statusChangedAt: Date?
  public var history: [StatusChange]
  public var attachments: [Attachment]
  /// End-to-end mode: true when this device holds no key that opens the letter.
  public var locked: Bool = false
  /// End-to-end mode: the letter exists but nobody has sealed it to this reader yet (`envelopes: []`). For a
  /// writer it is a reply recorded while they had no keys; a member of their group adds their envelope the
  /// next time one signs in (API PR #95). Not an empty letter, and not a lost one.
  public var awaitingShare: Bool = false
  /// Why a `returned` letter came back; nil otherwise.
  public var returnReason: ReturnReason? = nil
  /// Why this queued letter is held; nil when it is not.
  public var heldReason: HeldReason? = nil
  /// The returned letter this one was sent again for.
  public var resendOf: Int? = nil
  /// For a returned letter: what was sent in its place, if anything.
  public var resentAs: [Resend] = []

  public var isHeld: Bool { status == .queued && heldReason != nil }
  /// What the status chip says. A hold replaces "Queued": that word tells a writer a group will print the
  /// letter, and for a held one that is false, which is the whole point of telling them.
  public var statusLabel: String { isHeld ? "On hold" : status.label }
  /// What the group wrote when it recorded the return. Never encrypted, in any mode.
  public var returnNote: String? { history.last { $0.to == .returned }?.note }
  /// A returned letter of one's own can be sent again, once.
  public var canSendAgain: Bool { !fromPrisoner && status == .returned && resentAs.isEmpty }

  /// The brief's rule: a writer may edit or delete only while the letter is queued.
  public var canEdit: Bool { !fromPrisoner && status == .queued }
}

public struct LastMessage: Equatable, Sendable {
  public let id: Int
  public let fromPrisoner: Bool
  public let status: LetterStatus
  public let at: Date?
  public let preview: String?
}

/// A conversation with one prisoner. Not called `Thread`, which Foundation already uses.
public struct LetterThread: Equatable, Identifiable, Sendable {
  public let id: Int
  public let prisonerId: Int
  public let prisoner: Prisoner?
  public let lastMessage: LastMessage?
  public let lastActivity: Date?
  public var letters: [Letter]
  /// The account on the writer's side; groups use it to label threads and to know if they may write in them.
  public let writer: ThreadWriter?

  public var title: String { prisoner?.name ?? "Prisoner #\(prisonerId)" }
}

/// How a letter to this facility will be routed, worked out before sending so the writer sees it.
public enum RelayChoice: Equatable, Sendable {
  /// Exactly one relay group: the server will pick it; show it.
  case automatic(SupportGroup)
  /// No relay group and the facility accepts direct mail.
  case direct
  /// Several relay groups: the writer may (or, for relay-only facilities, must) choose.
  case choose(options: [SupportGroup], required: Bool)
  /// Relay-only facility with no relay group listed: nothing can be sent yet.
  case blocked(reason: String)
}

/// Mirrors the API's resolution rules (README, "Relay group") so the UI can explain them up front.
public func resolveRelay(_ facility: Facility?) -> RelayChoice {
  guard let facility else { return .direct }
  let groups = facility.relayGroups.filter(\.isActive)
  let relayOnly = facility.routing == .relayOnly
  switch groups.count {
  case 0:
    return relayOnly
      ? .blocked(reason: "\(facility.name) only accepts letters through a relay group, and none is listed yet. Ask a support group before writing.")
      : .direct
  case 1: return .automatic(groups[0])
  default: return .choose(options: groups, required: relayOnly)
  }
}

/// A rough printed-page estimate for the counter under the editor; one typed page is about 3,000 characters.
public func estimatePages(characters: Int) -> Int { characters <= 0 ? 1 : (characters + 2_999) / 3_000 }
