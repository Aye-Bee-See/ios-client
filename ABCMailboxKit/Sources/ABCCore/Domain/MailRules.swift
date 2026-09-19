import Foundation

/// One tag from the API's mail-rule vocabulary, with its default English wording.
public struct MailRule: Equatable, Sendable {
  public let tag: String
  public let category: String
  public let label: String
  public let description: String?

  init(_ tag: String, _ category: String, _ label: String, _ description: String?) {
    self.tag = tag
    self.category = category
    self.label = label
    self.description = description
  }
}

/// The vocabulary the app knows at this moment: the live one when it has been
/// fetched, otherwise the compiled-in copy. A tag that neither knows still
/// displays (as readable text made from the tag), and never breaks anything:
/// the API's contract is that clients ignore what they do not understand.
public struct MailRuleCatalog: Sendable {
  private let categories: [String]
  private let byTag: [String: MailRule]

  init(categories: [String], rules: [MailRule]) {
    self.categories = categories
    self.byTag = Dictionary(rules.map { ($0.tag, $0) }, uniquingKeysWith: { first, _ in first })
  }

  public func resolve(_ tag: String) -> MailRule { byTag[tag] ?? MailRule(tag, "other", tag.humanisedTag, nil) }

  /// Rules in the vocabulary's display order, unknown tags last, duplicates dropped. `details` is what
  /// the facility itself says about its rules, and wins: admins add and retire rules while the app is
  /// running, so a tag can be newer than the list this catalog was built from, or retired and no
  /// longer on it at all.
  public func resolveAll(_ tags: [String], details: [MailRule] = []) -> [MailRule] {
    let fromFacility = Dictionary(details.map { ($0.tag, $0) }, uniquingKeysWith: { first, _ in first })
    var seen = Set<String>()
    return tags.filter { seen.insert($0).inserted }
      .map { fromFacility[$0] ?? resolve($0) }
      .enumerated()
      .sorted { a, b in
        let ca = categories.firstIndex(of: a.element.category) ?? Int.max, cb = categories.firstIndex(of: b.element.category) ?? Int.max
        return ca != cb ? ca < cb : a.offset < b.offset
      }
      .map(\.element)
  }

  public static let compiled = MailRuleCatalog(categories: CompiledMailRules.categories, rules: CompiledMailRules.rules)
}

/// A facility's mail rules: tags plus the three that carry a value.
public struct MailRules: Equatable, Sendable {
  public let rules: [MailRule]
  public let pageLimit: Int?
  public let photoLimit: Int?
  /// ISO 639-1 codes, lower case; empty means no language rule recorded.
  public let languages: [String]

  public init(rules: [MailRule] = [], pageLimit: Int? = nil, photoLimit: Int? = nil, languages: [String] = []) {
    self.rules = rules
    self.pageLimit = pageLimit
    self.photoLimit = photoLimit
    self.languages = languages
  }

  public var isEmpty: Bool { rules.isEmpty && pageLimit == nil && photoLimit == nil && languages.isEmpty }
  public func has(_ tag: String) -> Bool { rules.contains { $0.tag == tag } }

  /// Tags the app acts on. Everything else is display only.
  public var forbidsPhotos: Bool { has(Self.noPhotos) }

  public var languageNames: [String] {
    let english = Locale(identifier: "en")
    return languages.map { code in
      let name = english.localizedString(forLanguageCode: code) ?? code
      return name.prefix(1).uppercased() + name.dropFirst()
    }
  }

  /// Every rule as a display line: tags first, then the valued ones.
  public func lines() -> [String] {
    var out = rules.map(\.label)
    if let pageLimit { out.append("At most \(pageLimit) page\(pageLimit == 1 ? "" : "s") per letter") }
    if let photoLimit { out.append("At most \(photoLimit) photo\(photoLimit == 1 ? "" : "s") per letter") }
    if !languages.isEmpty { out.append("Accepted languages: \(languageNames.joined(separator: ", "))") }
    return out
  }

  public static let noPhotos = "no_photos"
  public static let handwrittenOnly = "handwritten_only"
  public static let postcardsOnly = "postcards_only"
  public static let originalsDestroyed = "originals_destroyed"
  public static let deliveryNotConfirmed = "delivery_not_confirmed"
}

/// Something the compose screen tells the writer because of the facility's rules.
public struct ComposeAdvice: Equatable, Sendable {
  public let text: String
  public let warning: Bool
}

/// What the rules mean for the letter being written. Pure, so it is unit tested.
/// Nothing here blocks sending: page counts are estimates and groups know their
/// facilities better than a tag does. The one hard effect (no image attachments
/// where pictures are refused) is enforced by the attachment picker, using
/// `MailRules.forbidsPhotos`.
public func composeAdvice(rules: MailRules, estimatedPages: Int, imageAttachments: Int) -> [ComposeAdvice] {
  var out: [ComposeAdvice] = []
  if let limit = rules.pageLimit, estimatedPages > limit {
    out.append(ComposeAdvice(text: "This is about \(estimatedPages) pages, and this facility accepts at most \(limit). Consider splitting it into two letters.", warning: true))
  }
  if !rules.languages.isEmpty {
    out.append(ComposeAdvice(text: "Letters here must be written in \(rules.languageNames.joined(separator: " or ")). If that is not your language, ask your relay group about translation.", warning: false))
  }
  if rules.forbidsPhotos {
    out.append(ComposeAdvice(text: "This facility refuses pictures, so image attachments are turned off. A PDF can still be attached.", warning: false))
  }
  if let limit = rules.photoLimit, imageAttachments > limit {
    out.append(ComposeAdvice(text: "This facility accepts at most \(limit) photo\(limit == 1 ? "" : "s") per letter; you have attached \(imageAttachments).", warning: true))
  }
  if rules.has(MailRules.handwrittenOnly) {
    out.append(ComposeAdvice(text: "Only handwritten letters are accepted here. Attach a scan of a handwritten letter, or tell your relay group in the note that it needs copying by hand.", warning: true))
  }
  if rules.has(MailRules.postcardsOnly) {
    out.append(ComposeAdvice(text: "Only postcards are accepted here. Keep it short enough to fit one.", warning: true))
  }
  if rules.has(MailRules.originalsDestroyed) {
    out.append(ComposeAdvice(text: "Mail here is scanned and the original destroyed; the prisoner sees a copy.", warning: false))
  }
  if rules.has(MailRules.deliveryNotConfirmed) {
    out.append(ComposeAdvice(text: "Delivery to this facility cannot be confirmed. Do not send anything irreplaceable.", warning: false))
  }
  return out
}
