import ABCCore
import SwiftUI

private let prisonerStatuses = [("incarcerated", "Incarcerated"), ("pretrial", "Awaiting trial"), ("free", "Released")].map { (value: $0.0, label: $0.1) }
private let routings = Routing.allCases.filter { $0 != .unknown }.map { (value: $0.key, label: $0.label) }
private let networkRoles = [("collecting", "Collecting letters"), ("relay", "Mailing relay")].map { (value: $0.0, label: $0.1) }

/// The prisoners list. Also the "Write to…" picker: there `onPick` takes the tap instead of opening the profile.
struct PrisonersView: View {
  @State private var list: FilteredList<PrisonerFilter, Prisoner>
  private let app: AppModel
  private let title: String
  private let onPick: ((Int) -> Void)?

  init(app: AppModel, title: String = "Political prisoners", onPick: ((Int) -> Void)? = nil) {
    self.app = app
    self.title = title
    self.onPick = onPick
    let directory = app.container.directory
    _list = State(initialValue: FilteredList(filter: PrisonerFilter()) { try await directory.prisoners($0, page: $1, pageSize: $2) })
  }

  var body: some View {
    PagedList(loader: list.loader, emptyText: "No prisoners match.") {
      VStack(alignment: .leading, spacing: 8) {
        SearchField(text: $list.filter.query, placeholder: "Search by name")
        ChipRow(options: prisonerStatuses, selected: $list.filter.status)
        ChipRow(options: [(value: true, label: "Featured")], selected: $list.filter.featured, allLabel: "Everyone")
      }
      .padding(.horizontal, 20).padding(.vertical, 8)
    } row: { p in
      PrisonerRow(prisoner: p) { if let onPick { onPick(p.id) } else { app.push(.prisoner(p.id)) } }
    }
    .navigationTitle(title)
    .navigationBarTitleDisplayMode(.inline)
    .task { await list.start() }
  }
}

struct FacilitiesView: View {
  @State private var list: FilteredList<FacilityFilter, Facility>
  private let app: AppModel

  init(app: AppModel) {
    self.app = app
    let directory = app.container.directory
    _list = State(initialValue: FilteredList(filter: FacilityFilter()) { try await directory.facilities($0, page: $1, pageSize: $2) })
  }

  var body: some View {
    PagedList(loader: list.loader, emptyText: "No facilities match.") {
      VStack(alignment: .leading, spacing: 8) {
        SearchField(text: $list.filter.query, placeholder: "Search facilities")
        ChipRow(options: routings, selected: $list.filter.routing)
        ChipRow(options: [(value: true, label: "Relay available")], selected: $list.filter.relay, allLabel: "Any routing")
      }
      .padding(.horizontal, 20).padding(.vertical, 8)
    } row: { f in
      RecordRow(
        title: f.name, secondary: f.shortLocation.isEmpty ? nil : f.shortLocation,
        subtitle: f.routing.label + (f.relayGroups.isEmpty ? "" : " · via " + f.relayGroups.map(\.name).joined(separator: ", ")),
        notice: f.verification.isStale() ? "⚠ Not verified in over 6 months" : nil
      ) { app.push(.facility(f.id)) }
    }
    .navigationTitle("Facilities & mail rules")
    .navigationBarTitleDisplayMode(.inline)
    .task { await list.start() }
  }
}

struct GroupsView: View {
  @State private var list: FilteredList<GroupFilter, SupportGroup>
  private let app: AppModel

  init(app: AppModel) {
    self.app = app
    let directory = app.container.directory
    _list = State(initialValue: FilteredList(filter: GroupFilter()) { try await directory.groups($0, page: $1, pageSize: $2) })
  }

  var body: some View {
    PagedList(loader: list.loader, emptyText: "No groups match.") {
      VStack(alignment: .leading, spacing: 8) {
        SearchField(text: $list.filter.query, placeholder: "Search groups")
        ChipRow(options: networkRoles, selected: $list.filter.networkRole)
        ChipRow(options: ServiceLabels.all.map { (value: $0.key, label: $0.label) }, selected: $list.filter.service, allLabel: "Any service")
      }
      .padding(.horizontal, 20).padding(.vertical, 8)
    } row: { g in
      RecordRow(
        title: g.name, secondary: g.location.isEmpty ? nil : g.location,
        subtitle: g.about.map { $0.count > 140 ? String($0.prefix(137)) + "…" : $0 },
        tags: Array(g.services.map(ServiceLabels.label).prefix(4))
      ) { app.push(.group(g.id)) }
    }
    .navigationTitle("Support groups")
    .navigationBarTitleDisplayMode(.inline)
    .task { await list.start() }
  }
}
