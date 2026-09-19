import ABCCore
import SwiftUI

/// The Directory tab's front page, after `index.html`: the pitch, three doors, featured prisoners.
struct DirectoryHomeView: View {
  let app: AppModel
  @State private var featured: Loadable<[Prisoner]> = .loading

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        VStack(alignment: .leading, spacing: 8) {
          Text("Letters matter.").font(Theme.display)
          Text("Write one today.").font(Theme.headlineSmall).foregroundStyle(Theme.red)
          Text("Browse prisoner profiles, find a support group near you, and learn exactly what each facility requires before you write.")
            .font(Theme.bodyLarge).padding(.top, 8)
        }
        .padding(.horizontal, 20).padding(.vertical, 24)

        rule
        door("Prisoners", "Profiles maintained by support groups", .prisoners); rule
        door("Facilities", "Mail rules and routing for each prison", .facilities); rule
        door("Groups", "Chapters collecting and relaying letters", .groups); rule

        SectionTitle("Prisoners seeking correspondence").padding(.horizontal, 20).padding(.vertical, 8)
        switch featured {
        case .loading: LoadingBox()
        case .failed(let error): ErrorBox(error: error) { Task { await load() } }
        case .loaded(let prisoners):
          if prisoners.isEmpty { Muted("No featured prisoners yet.", font: Theme.bodyLarge).padding(20) }
          ForEach(prisoners) { p in PrisonerRow(prisoner: p) { app.push(.prisoner(p.id)) }; rule }
        }
      }
      .frame(maxWidth: 700, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
    .refreshable { await load() }
    .background(Theme.paper)
    .savedCopyBanner(app)
    .toolbar(.hidden, for: .navigationBar)
    .task { if featured.value == nil { await load() } }
  }

  private var rule: some View { Divider().overlay(Theme.rule) }

  private func load() async {
    if featured.value == nil { featured = .loading }
    featured = await .from { try await app.container.directory.featuredPrisoners() }
  }

  private func door(_ title: String, _ subtitle: String, _ route: Route) -> some View {
    Button { app.push(route) } label: {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text(title).font(Theme.titleLarge).foregroundStyle(Theme.ink)
          Muted(subtitle)
        }
        Spacer()
        Image(systemName: "arrow.right").foregroundStyle(Theme.red)
      }
      .padding(.horizontal, 20).padding(.vertical, 16)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

struct PrisonerRow: View {
  let prisoner: Prisoner
  var horizontalPadding: CGFloat = 20
  let action: () -> Void

  var body: some View {
    let p = prisoner
    let heldAt = p.facility.map { f in "Held at: \(f.name)" + (f.shortLocation.isEmpty ? "" : ", \(f.shortLocation)") }
    let since = p.detainedSinceYear.map { "Since: \($0)" }
    RecordRow(
      title: p.name, secondary: p.birthName,
      subtitle: [heldAt, since, "Est. release: \(p.releaseSummary)"].compactMap { $0 }.joined(separator: "  ·  "),
      notice: p.statusNotice, tags: Array(p.interests.prefix(4)), horizontalPadding: horizontalPadding, action: action
    )
  }
}
