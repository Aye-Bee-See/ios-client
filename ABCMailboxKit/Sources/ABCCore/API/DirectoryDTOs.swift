import Foundation

// The public directory: prisons, prisoners, chapters. Every call works without
// a token; signed-in staff simply see more records.

struct PrisonerDTO: Decodable {
  let id: Int
  let birthName: String?
  let chosenName: String?
  let aliases: [String]?
  let prison: Int?
  let country: String?
  let inmateID: String?
  let releaseDate: String?
  let detainedSince: String?
  let sentence: String?
  let charges: String?
  let estimatedRelease: String?
  let bio: String?
  let interests: [String]?
  let photoUrl: String?
  let supportWebsite: String?
  let donationInfo: String?
  let status: String?
  let statusNotice: String?
  let featured: Bool?
  let verifiedBy: Int?
  let verifiedAt: String?
  let prisonDetails: PrisonDTO?
  let supportGroups: [ChapterDTO]?

  private enum CodingKeys: String, CodingKey {
    case id, birthName, chosenName, aliases, prison, country, inmateID, releaseDate, detainedSince, sentence, charges
    case estimatedRelease, bio, interests, photoUrl, supportWebsite, donationInfo, status, statusNotice, featured, verifiedBy, verifiedAt
    case prisonDetails = "prison_details", supportGroups = "support_groups"
  }
}

struct PrisonDTO: Decodable {
  let id: Int
  let prisonName: String
  let address: [String: JSONValue]?
  let country: String?
  let routing: String?
  let scanService: String?
  let notes: String?
  let verifiedBy: Int?
  let verifiedAt: String?
  /// Tags from the master list of mail rules (API PRs #86, #93); the three valued rules sit beside them.
  let mailRules: [String]?
  /// The same rules with their wording (API PR #93). The master list can change while the app runs,
  /// since admins add and retire rules, so this is the authority for how a facility's rules read.
  let mailRuleDetails: [MailRuleDTO]?
  let pageLimit: Int?
  let photoLimit: Int?
  let mailLanguages: [String]?
  let prisoners: [PrisonerDTO]?
  let relayGroups: [ChapterDTO]?

  private enum CodingKeys: String, CodingKey {
    case id, prisonName, address, country, routing, scanService, notes, verifiedBy, verifiedAt, mailRules, pageLimit, photoLimit, mailLanguages, prisoners
    case relayGroups = "relay_groups", mailRuleDetails = "mail_rule_details"
  }
}

struct MailRuleVocabularyDTO: Decodable {
  let categories: [String]?
  let rules: [MailRuleDTO]?
}

struct MailRuleDTO: Decodable {
  let tag: String
  let category: String?
  let label: String?
  let description: String?
}

struct ChapterDTO: Decodable {
  let id: Int
  let name: String
  let location: [String: JSONValue]?
  let subregion: String?
  let country: String?
  let about: String?
  let website: String?
  let email: String?
  let socialLinks: [String: String?]?
  let services: [String]?
  let announcement: String?
  let networkRole: String?
  let accountStatus: String?
  let supportedPrisoners: [PrisonerDTO]?
  let relayPrisons: [PrisonDTO]?
  /// Present when the chapter is embedded on a prisoner as a support group.
  let prisonerSupport: PrisonerSupportDTO?

  private enum CodingKeys: String, CodingKey {
    case id, name, location, subregion, country, about, website, email, socialLinks, services, announcement, networkRole, accountStatus
    case supportedPrisoners = "supported_prisoners", relayPrisons = "relay_prisons", prisonerSupport = "PrisonerSupport"
  }
}

struct PrisonerSupportDTO: Decodable {
  let description: String?
}
