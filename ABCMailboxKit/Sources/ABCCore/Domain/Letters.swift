import Foundation

public enum LetterStatus: String, CaseIterable, Sendable {
  case queued, printed, mailed, received
  case unknown = ""

  public var key: String { rawValue }

  public var label: String {
    switch self {
    case .queued: return "Queued"
    case .printed: return "Printed"
    case .mailed: return "Mailed"
    case .received: return "Received"
    case .unknown: return "Unknown"
    }
  }

  public static func from(key: String?) -> LetterStatus { key.flatMap { $0.isEmpty ? nil : LetterStatus(rawValue: $0) } ?? .unknown }
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
  public let history: [StatusChange]
  public var attachments: [Attachment]
  /// End-to-end mode: true when this device holds no key that opens the letter.
  public var locked: Bool = false
  /// End-to-end mode: the letter exists but nobody has sealed it to this reader yet (`envelopes: []`). For a
  /// writer it is a reply recorded while they had no keys; a member of their group adds their envelope the
  /// next time one signs in (API PR #95). Not an empty letter, and not a lost one.
  public var awaitingShare: Bool = false

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
  public let letters: [Letter]
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
