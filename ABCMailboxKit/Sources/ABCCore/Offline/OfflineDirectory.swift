import Foundation
import Observation

/// How many of each the copy holds; shown so a volunteer can see it is complete before a letter night.
public struct DirectoryCounts: Equatable, Sendable {
  public let prisoners: Int
  public let facilities: Int
  public let groups: Int
}

/// A copy of the public directory on the phone, for a letter-writing night in a room with
/// no signal: everyone's address and mail rules, searchable, as of the last download.
/// Reads answer with the same DTOs the API client produces, so callers map them the same way.
///
/// Android keeps its copy in SQLite and filters with SQL. Here the copy is one file, read
/// into memory and filtered in Swift: a directory is hundreds of records, not millions, and
/// it spares the app a database it has no other use for (see docs/DECISIONS.md). What must
/// match is the behaviour, and the tests pin it to Android's: a search has to give a
/// volunteer the same results in the basement as at home.
@MainActor @Observable
public final class OfflineDirectory {
  /// When the copy was made; nil means nothing has been downloaded yet.
  public private(set) var savedAt: Date?
  public private(set) var counts = DirectoryCounts(prisoners: 0, facilities: 0, groups: 0)

  @ObservationIgnored private let api: APIClient
  @ObservationIgnored private let file: URL
  @ObservationIgnored private var copy: Copy?
  @ObservationIgnored private var downloading: Task<Void, Error>?

  /// The API's maximum page size.
  private static let pageSize = 100
  /// 20,000 records: far beyond any real directory, and a stop for a server that never says "done".
  private static let maxPages = 200

  init(api: APIClient, directory: URL) {
    self.api = api
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    // It can be downloaded again, so it has no business in a backup.
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    var dir = directory
    try? dir.setResourceValues(values)
    file = directory.appendingPathComponent("directory.json")
    if let data = try? Data(contentsOf: file), let stored = try? JSONDecoder().decode(Stored.self, from: data) { adopt(Copy(stored)) }
  }

  private func adopt(_ new: Copy) {
    copy = new
    savedAt = new.savedAt
    counts = DirectoryCounts(prisoners: new.prisoners.count, facilities: new.facilities.count, groups: new.groups.count)
  }

  // MARK: Downloading

  /// Downloads everything and swaps it in. Nothing changes on disk unless the whole download succeeded.
  /// A second caller joins the download already running.
  public func download() async throws {
    if let downloading { return try await downloading.value }
    let task = Task { try await self.reallyDownload() }
    downloading = task
    defer { downloading = nil }
    try await task.value
  }

  /// Downloads only if there is no copy or it is older than `maxAgeHours`. Failures are silent: this is housekeeping.
  public func downloadIfOlderThan(hours maxAgeHours: Double = 24) async {
    if let savedAt, savedAt > Date().addingTimeInterval(-maxAgeHours * 3600) { return }
    try? await download()
  }

  private func reallyDownload() async throws {
    let prisoners = try await everyPage("prisoner/prisoners")
    let facilities = try await everyPage("prison/prisons")
    let groups = try await everyPage("chapter/chapters")
    // The rule list is a convenience (facilities carry their own rules' wording), so its failure does not fail the download.
    let rules = (try? await api.get("prison/mail-rules", anonymous: true) as APIEnvelope<JSONValue>)?.data

    let stored = Stored(savedAt: Date(), prisoners: prisoners, facilities: facilities, groups: groups, mailRules: rules)
    let file = file
    // Off the main thread: a big directory is a few megabytes of JSON. The write is atomic (a temporary
    // file renamed into place), so a reader sees the old directory or the new one, never half of each.
    let new = try await Task.detached(priority: .utility) { () -> Copy in
      try JSONEncoder().encode(stored).write(to: file, options: .atomic)
      return Copy(stored)
    }.value
    adopt(new)
  }

  /// Walks a paginated list to its end. `total` comes with every page, so the loop knows when it has everything.
  ///
  /// Every call is anonymous, so the copy holds exactly what the public sees: a group member's or
  /// admin's view includes unpublished records and verification notes, and those must not land in a
  /// file that outlives their session. Rows are kept as the raw JSON the API sent. A `full=true`
  /// list row has the same shape as the single read, so a detail page can be rebuilt offline.
  private func everyPage(_ path: String) async throws -> [JSONValue] {
    var rows: [JSONValue] = []
    for page in 1...Self.maxPages {
      let envelope: APIEnvelope<[JSONValue]> = try await api.get(path, query: [("page", String(page)), ("page_size", String(Self.pageSize)), ("full", "true")], anonymous: true)
      let batch = envelope.data ?? []
      rows += batch
      if batch.isEmpty || rows.count >= (envelope.total ?? rows.count) { break }
    }
    return rows
  }

  // MARK: Reading

  func prisoners(_ filter: PrisonerFilter, page: Int, pageSize: Int) -> Page<PrisonerDTO>? {
    guard let copy else { return nil }
    let q = filter.query.trimmed.lowercased()
    let rows = copy.prisoners.filter { r in
      (q.isEmpty || r.searchText.contains(q)) && (filter.status == nil || r.dto.status == filter.status) && (filter.country == nil || r.dto.country == filter.country)
        && (filter.featured == nil || (r.dto.featured ?? false) == filter.featured) && (filter.facilityId == nil || r.dto.prison == filter.facilityId)
    }
    return Self.page(rows, sort: filter.sort, page: page, pageSize: pageSize)
  }

  func facilities(_ filter: FacilityFilter, page: Int, pageSize: Int) -> Page<PrisonDTO>? {
    guard let copy else { return nil }
    let q = filter.query.trimmed.lowercased()
    let rows = copy.facilities.filter { r in
      // At least one active relay group, as the server's `relay=true` means.
      let hasRelay = (r.dto.relayGroups ?? []).contains { $0.accountStatus == nil || $0.accountStatus == "active" }
      return (q.isEmpty || r.searchText.contains(q)) && (filter.country == nil || r.dto.country == filter.country)
        && (filter.routing == nil || r.dto.routing == filter.routing) && (filter.relay == nil || hasRelay == filter.relay)
    }
    return Self.page(rows, sort: filter.sort, page: page, pageSize: pageSize)
  }

  func groups(_ filter: GroupFilter, page: Int, pageSize: Int) -> Page<ChapterDTO>? {
    guard let copy else { return nil }
    let q = filter.query.trimmed.lowercased()
    let rows = copy.groups.filter { r in
      (q.isEmpty || r.searchText.contains(q)) && (filter.country == nil || r.dto.country == filter.country)
        // A whole service key, never half of one ("legal" is not "legal_support").
        && (filter.service.map { (r.dto.services ?? []).contains($0) } ?? true)
        // A group marked `both` answers to either role, as on the server.
        && (filter.networkRole == nil || r.dto.networkRole == filter.networkRole || r.dto.networkRole == "both")
    }
    return Self.page(rows, sort: filter.sort, page: page, pageSize: pageSize)
  }

  func prisoner(id: Int) -> PrisonerDTO? { copy?.prisoners.first { $0.id == id }?.dto }
  func facility(id: Int) -> PrisonDTO? { copy?.facilities.first { $0.id == id }?.dto }
  func group(id: Int) -> ChapterDTO? { copy?.groups.first { $0.id == id }?.dto }
  func mailRules() -> MailRuleVocabularyDTO? { copy?.mailRules }

  /// One ordering serves every sort the API offers; an unknown sort falls through to id, the API's default.
  private static func page<DTO>(_ rows: [Row<DTO>], sort: String, page: Int, pageSize: Int) -> Page<DTO> {
    let sorted = rows.sorted { a, b in
      switch sort {
      case "name":
        let byName = a.sortName.caseInsensitiveCompare(b.sortName)
        if byName != .orderedSame { return byName == .orderedAscending }
      case "newest": if a.createdAt != b.createdAt { return a.createdAt > b.createdAt }
      case "oldest": if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
      default: break
      }
      return a.id < b.id
    }
    let start = max(0, (page - 1) * pageSize)
    return Page(items: sorted.dropFirst(start).prefix(pageSize).map(\.dto), total: sorted.count, page: page, pageSize: pageSize)
  }

  // MARK: The copy

  /// What is on disk: each record as the JSON the API sent. Keeping the JSON whole means the API can
  /// add fields without a migration here, and the offline path reuses the DTOs and mappers of the online one.
  struct Stored: Codable, Sendable {
    let savedAt: Date
    let prisoners: [JSONValue]
    let facilities: [JSONValue]
    let groups: [JSONValue]
    let mailRules: JSONValue?
  }

  /// A record with only the extra facts needed to search and sort it the way the server does.
  struct Row<DTO>: @unchecked Sendable {
    let id: Int
    let dto: DTO
    /// Chosen name, else birth name: what the server sorts `name` by.
    let sortName: String
    /// Lower-cased names, which is what `q` matches on the server.
    let searchText: String
    /// ISO-8601 in UTC sorts correctly as text. Missing sorts as oldest.
    let createdAt: String
  }

  /// What is in memory.
  struct Copy: @unchecked Sendable {
    let savedAt: Date
    let prisoners: [Row<PrisonerDTO>]
    let facilities: [Row<PrisonDTO>]
    let groups: [Row<ChapterDTO>]
    let mailRules: MailRuleVocabularyDTO?

    init(_ stored: Stored) {
      savedAt = stored.savedAt
      // One record the app cannot read must not cost the whole directory, so a bad row is skipped, not thrown.
      prisoners = stored.prisoners.compactMap { raw in
        guard let p = try? raw.decoded(as: PrisonerDTO.self) else { return nil }
        let names = [p.chosenName, p.birthName].compactMap { $0?.nonBlank }
        return Row(id: p.id, dto: p, sortName: names.first ?? "", searchText: names.joined(separator: "\n").lowercased(), createdAt: raw.createdAt)
      }
      facilities = stored.facilities.compactMap { raw in
        guard let f = try? raw.decoded(as: PrisonDTO.self) else { return nil }
        return Row(id: f.id, dto: f, sortName: f.prisonName, searchText: f.prisonName.lowercased(), createdAt: raw.createdAt)
      }
      groups = stored.groups.compactMap { raw in
        guard let g = try? raw.decoded(as: ChapterDTO.self) else { return nil }
        return Row(id: g.id, dto: g, sortName: g.name, searchText: g.name.lowercased(), createdAt: raw.createdAt)
      }
      mailRules = try? stored.mailRules?.decoded(as: MailRuleVocabularyDTO.self)
    }
  }
}

private extension JSONValue {
  var createdAt: String {
    if case .object(let o) = self, case .string(let s)? = o["createdAt"] { return s }
    return ""
  }
}
