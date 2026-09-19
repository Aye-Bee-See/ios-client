import Foundation

// What the screens work with. These carry the facts the UI needs already
// derived (display names, address lines, staleness) so that the API's shape
// is absorbed once, in the mappers, and never in a view.

public struct Verification: Equatable, Sendable {
  public let byGroupId: Int?
  public let at: Date?

  /// Six months, matching the web site's "6+ months unverified" warning and the API's `stale` filter.
  public func isStale(now: Date = Date()) -> Bool {
    guard let at else { return true }
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(identifier: "UTC")!
    let from = utc.startOfDay(for: at), to = utc.startOfDay(for: now)
    return (utc.dateComponents([.month], from: from, to: to).month ?? 0) >= 6
  }
}

public enum Routing: String, CaseIterable, Sendable {
  case direct = "direct"
  case scanOnly = "scan_only"
  case directAndScan = "direct_and_scan"
  case relayOnly = "relay_only"
  case unknown = ""

  public var key: String { rawValue }

  public var label: String {
    switch self {
    case .direct: return "Direct mail"
    case .scanOnly: return "Scan service only"
    case .directAndScan: return "Direct mail or scan service"
    case .relayOnly: return "Relay only"
    case .unknown: return "Routing unknown"
    }
  }

  public var explanation: String {
    switch self {
    case .direct: return "Letters are mailed straight to the facility."
    case .scanOnly: return "Physical mail is not accepted; letters go through a scanning service."
    case .directAndScan: return "Letters can be mailed or sent through a scanning service."
    case .relayOnly: return "Direct mail is not accepted. A relay group must mail the letter locally."
    case .unknown: return "Check with a support group before writing."
    }
  }

  public static func from(key: String?) -> Routing { key.flatMap { $0.isEmpty ? nil : Routing(rawValue: $0) } ?? .unknown }
}

public struct Facility: Equatable, Identifiable, Sendable {
  public let id: Int
  public let name: String
  public let addressLines: [String]
  public let country: String?
  public let routing: Routing
  public let scanService: String?
  public let notes: String?
  public let verification: Verification
  public let prisoners: [Prisoner]
  public let rules: MailRules
  public let relayGroups: [SupportGroup]

  public var shortLocation: String { [addressLines.last, country].compactMap { $0 }.joined(separator: ", ") }
}

public struct Prisoner: Equatable, Identifiable, Sendable {
  public let id: Int
  public let name: String
  public let birthName: String?
  public let aliases: [String]
  public let facilityId: Int?
  /// A box, because a facility lists prisoners and a prisoner names a facility.
  private let facilityBox: Box<Facility>?
  public var facility: Facility? { facilityBox?.value }
  public let country: String?
  public let detainedSince: Date?
  public let releaseDate: Date?
  public let sentence: String?
  public let charges: String?
  public let estimatedRelease: String?
  public let bio: String?
  public let interests: [String]
  public let photoUrl: String?
  public let supportWebsite: String?
  public let donationInfo: String?
  public let status: String?
  public let statusNotice: String?
  public let featured: Bool
  public let verification: Verification
  public let supportGroups: [SupportGroup]
  /// The facility-issued number; most facilities refuse mail without it on the envelope.
  public let inmateId: String?

  init(
    id: Int, name: String, birthName: String? = nil, aliases: [String] = [], facilityId: Int? = nil, facility: Facility? = nil, country: String? = nil,
    detainedSince: Date? = nil, releaseDate: Date? = nil, sentence: String? = nil, charges: String? = nil, estimatedRelease: String? = nil, bio: String? = nil,
    interests: [String] = [], photoUrl: String? = nil, supportWebsite: String? = nil, donationInfo: String? = nil, status: String? = nil, statusNotice: String? = nil,
    featured: Bool = false, verification: Verification = Verification(byGroupId: nil, at: nil), supportGroups: [SupportGroup] = [], inmateId: String? = nil
  ) {
    self.id = id; self.name = name; self.birthName = birthName; self.aliases = aliases; self.facilityId = facilityId
    self.facilityBox = facility.map(Box.init); self.country = country; self.detainedSince = detainedSince; self.releaseDate = releaseDate
    self.sentence = sentence; self.charges = charges; self.estimatedRelease = estimatedRelease; self.bio = bio; self.interests = interests
    self.photoUrl = photoUrl; self.supportWebsite = supportWebsite; self.donationInfo = donationInfo; self.status = status
    self.statusNotice = statusNotice; self.featured = featured; self.verification = verification; self.supportGroups = supportGroups; self.inmateId = inmateId
  }

  /// "Est. release" as the site shows it: the free-text estimate wins, then the date's year.
  public var releaseSummary: String {
    if let estimatedRelease, !estimatedRelease.isBlank { return estimatedRelease }
    if let releaseDate { return String(Calendar.utc.component(.year, from: releaseDate)) }
    return "Unknown"
  }

  public var detainedSinceYear: Int? { detainedSince.map { Calendar.utc.component(.year, from: $0) } }
}

/// The API's "chapter": a support group. Not called `Group`, which SwiftUI already uses.
public struct SupportGroup: Equatable, Identifiable, Sendable {
  public let id: Int
  public let name: String
  public let subregion: String?
  public let country: String?
  public let about: String?
  public let website: String?
  public let email: String?
  public let socialLinks: [String: String]
  public let services: [String]
  public let announcement: String?
  public let networkRole: String?
  public let accountStatus: String?
  public let supportedPrisoners: [Prisoner]
  public let relayPrisons: [Facility]
  /// How this group supports a particular prisoner, when embedded on that prisoner.
  public let supportDescription: String?

  init(
    id: Int, name: String, subregion: String? = nil, country: String? = nil, about: String? = nil, website: String? = nil, email: String? = nil,
    socialLinks: [String: String] = [:], services: [String] = [], announcement: String? = nil, networkRole: String? = nil, accountStatus: String? = nil,
    supportedPrisoners: [Prisoner] = [], relayPrisons: [Facility] = [], supportDescription: String? = nil
  ) {
    self.id = id; self.name = name; self.subregion = subregion; self.country = country; self.about = about; self.website = website; self.email = email
    self.socialLinks = socialLinks; self.services = services; self.announcement = announcement; self.networkRole = networkRole
    self.accountStatus = accountStatus; self.supportedPrisoners = supportedPrisoners; self.relayPrisons = relayPrisons; self.supportDescription = supportDescription
  }

  public var location: String { [subregion, country].compactMap { $0 }.joined(separator: ", ") }
  var isActive: Bool { accountStatus == nil || accountStatus == "active" }
}

/// Service keys the API accepts, with the labels the site uses.
public enum ServiceLabels {
  public static let all: [(key: String, label: String)] = [
    ("letter_collection", "Letter collection"),
    ("letter_writing_nights", "Letter writing nights"),
    ("domestic_mailing", "Domestic mailing"),
    ("international_mailing", "International mailing"),
    ("international_relay", "International relay"),
    ("translation_assistance", "Translation assistance"),
    ("legal_support_coordination", "Legal support coordination"),
    ("book_programs", "Book programs"),
  ]

  public static func label(_ key: String) -> String { all.first { $0.key == key }?.label ?? key.humanisedTag }
}

public enum NetworkRoles {
  public static func label(_ key: String?) -> String {
    switch key {
    case "collecting": return "Collecting group: gathers letters and forwards them to relay partners"
    case "relay": return "Relay group: prints and mails letters locally"
    case "both": return "Collects letters and relays mail"
    default: return "Role not set"
    }
  }
}

/// Lets two value types refer to each other.
final class Box<T: Equatable & Sendable>: Equatable, Sendable {
  let value: T
  init(_ value: T) { self.value = value }
  static func == (a: Box, b: Box) -> Bool { a.value == b.value }
}

extension Calendar {
  static let utc: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
  }()
}

extension String {
  var isBlank: Bool { allSatisfy(\.isWhitespace) }
  /// nil for nil, empty, and whitespace-only text: the API sends all three for "nothing".
  var nonBlank: String? { isBlank ? nil : self }
  /// "no_glitter_pens" as "No glitter pens".
  var humanisedTag: String {
    let spaced = replacingOccurrences(of: "_", with: " ")
    return spaced.prefix(1).uppercased() + spaced.dropFirst()
  }
}
