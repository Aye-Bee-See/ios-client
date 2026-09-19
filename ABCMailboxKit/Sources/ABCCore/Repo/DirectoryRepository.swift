import Foundation
import Observation

/// Everything the list screens can ask for; nil means "no filter".
public struct PrisonerFilter: Equatable, Sendable {
  public var query = ""
  public var status: String?
  public var country: String?
  public var featured: Bool?
  public var facilityId: Int?
  public var sort = "name"
  public init() {}
}

public struct FacilityFilter: Equatable, Sendable {
  public var query = ""
  public var country: String?
  public var routing: String?
  public var relay: Bool?
  public var sort = "name"
  public init() {}
}

public struct GroupFilter: Equatable, Sendable {
  public var query = ""
  public var country: String?
  public var service: String?
  public var networkRole: String?
  public var sort = "name"
  public init() {}
}

/// Where the directory on screen came from. Screens say so when it is the saved copy.
public enum DirectorySource: Equatable, Sendable {
  case live
  case saved(at: Date)
}

/// The public directory. `full=true` is used on single reads only, exactly as the brief says.
/// Reads go to the network first and fall back to the copy saved on the phone only when our
/// server cannot be reached.
@MainActor @Observable
public final class DirectoryRepository {
  /// Flips to `.saved` when a read had to be answered from the phone, and back on the next read that reaches the server.
  public private(set) var source: DirectorySource = .live

  @ObservationIgnored private let api: APIClient
  @ObservationIgnored private let offline: OfflineDirectory
  @ObservationIgnored private var liveCatalog: MailRuleCatalog?

  init(api: APIClient, offline: OfflineDirectory) {
    self.api = api
    self.offline = offline
  }

  /// The live master list, fetched once per process. Admins can change the list at any time
  /// (API PR #93), so it is only the fallback: each facility read carries the wording of its own
  /// rules (`mail_rule_details`), which the mapper prefers.
  private func catalog() async -> MailRuleCatalog {
    if let liveCatalog { return liveCatalog }
    let live = (try? await api.get("prison/mail-rules") as APIEnvelope<MailRuleVocabularyDTO>)?.data
    // Without a connection: the list saved with the offline copy, then the one compiled into the app.
    // Only a live list is kept for the rest of the process, so a connection that comes back is used.
    guard let fetched = live ?? offline.mailRules() else { return .compiled }
    let catalog = MailRuleCatalog(
      categories: fetched.categories ?? [],
      rules: (fetched.rules ?? []).map { MailRule($0.tag, $0.category ?? "other", $0.label ?? MailRuleCatalog.compiled.resolve($0.tag).label, $0.description) }
    )
    if live != nil { liveCatalog = catalog }
    return catalog
  }

  /// Network first. Only a failure to reach our server falls back to the saved copy: a 404 or a 403
  /// is the server's answer and stands. With no saved copy, or nothing saved for this read, the
  /// network error is what the screen shows.
  private func orSaved<T>(_ live: () async throws -> T, saved: () -> T?) async throws -> T {
    do {
      let value = try await live()
      source = .live
      return value
    } catch {
      guard AppError.from(error).meansNotReachingOurServer, let at = offline.savedAt, let value = saved() else { throw error }
      source = .saved(at: at)
      return value
    }
  }

  private func paging(_ page: Int, _ size: Int) -> APIClient.Query { [("page", String(page)), ("page_size", String(size))] }

  public func prisoners(_ filter: PrisonerFilter, page: Int, pageSize: Int) async throws -> Page<Prisoner> {
    let rows: Page<PrisonerDTO> = try await orSaved {
      let envelope: APIEnvelope<[PrisonerDTO]> = try await api.get("prisoner/prisoners", query: [
        ("q", filter.query.nonBlank), ("prison", filter.facilityId.map(String.init)), ("status", filter.status), ("country", filter.country),
        ("featured", filter.featured.map(String.init)), ("sort", filter.sort),
      ] + paging(page, pageSize))
      return envelope.toPage()
    } saved: { offline.prisoners(filter, page: page, pageSize: pageSize) }
    let c = await catalog()
    return rows.map { $0.toDomain(c) }
  }

  public func facilities(_ filter: FacilityFilter, page: Int, pageSize: Int) async throws -> Page<Facility> {
    let rows: Page<PrisonDTO> = try await orSaved {
      let envelope: APIEnvelope<[PrisonDTO]> = try await api.get("prison/prisons", query: [
        ("q", filter.query.nonBlank), ("country", filter.country), ("routing", filter.routing), ("relay", filter.relay.map(String.init)), ("sort", filter.sort),
      ] + paging(page, pageSize))
      return envelope.toPage()
    } saved: { offline.facilities(filter, page: page, pageSize: pageSize) }
    let c = await catalog()
    return rows.map { $0.toDomain(c) }
  }

  public func groups(_ filter: GroupFilter, page: Int, pageSize: Int) async throws -> Page<SupportGroup> {
    let rows: Page<ChapterDTO> = try await orSaved {
      let envelope: APIEnvelope<[ChapterDTO]> = try await api.get("chapter/chapters", query: [
        ("q", filter.query.nonBlank), ("country", filter.country), ("service", filter.service), ("networkRole", filter.networkRole), ("sort", filter.sort),
      ] + paging(page, pageSize))
      return envelope.toPage()
    } saved: { offline.groups(filter, page: page, pageSize: pageSize) }
    let c = await catalog()
    return rows.map { $0.toDomain(c) }
  }

  public func featuredPrisoners(limit: Int = 6) async throws -> [Prisoner] {
    var featured = PrisonerFilter()
    featured.featured = true
    featured.sort = "newest"
    let rows: [PrisonerDTO] = try await orSaved {
      let envelope: APIEnvelope<[PrisonerDTO]> = try await api.get("prisoner/prisoners", query: [("featured", "true"), ("sort", "newest")] + paging(1, limit))
      return envelope.data ?? []
    } saved: { offline.prisoners(featured, page: 1, pageSize: limit)?.items }
    let c = await catalog()
    return rows.map { $0.toDomain(c) }
  }

  public func prisoner(id: Int) async throws -> Prisoner {
    let dto: PrisonerDTO = try await orSaved {
      try (await api.get("prisoner/prisoner", query: [("id", String(id)), ("full", "true")]) as APIEnvelope<PrisonerDTO>).required("prisoner")
    } saved: { offline.prisoner(id: id) }
    return dto.toDomain(await catalog())
  }

  public func facility(id: Int) async throws -> Facility {
    let dto: PrisonDTO = try await orSaved {
      try (await api.get("prison/prison", query: [("id", String(id)), ("full", "true")]) as APIEnvelope<PrisonDTO>).required("facility")
    } saved: { offline.facility(id: id) }
    return dto.toDomain(await catalog())
  }

  public func group(id: Int) async throws -> SupportGroup {
    let dto: ChapterDTO = try await orSaved {
      try (await api.get("chapter/chapter", query: [("id", String(id)), ("full", "true")]) as APIEnvelope<ChapterDTO>).required("group")
    } saved: { offline.group(id: id) }
    return dto.toDomain(await catalog())
  }
}
