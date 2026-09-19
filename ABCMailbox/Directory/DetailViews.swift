import ABCCore
import SwiftUI

/// The prisoner page needs two reads: the prisoner (with its facility embedded)
/// and the facility itself, because only the facility read embeds relay groups.
/// The second is best-effort; the page renders without it.
struct PrisonerView: View {
  let app: AppModel
  let id: Int
  @State private var prisoner: Loadable<Prisoner> = .loading
  @State private var facilityDetail: Facility?

  var body: some View {
    LoadableView(state: prisoner, retry: { Task { await load() } }) { p in content(p) }
      .navigationTitle(prisoner.value?.name ?? "Prisoner")
      .navigationBarTitleDisplayMode(.inline)
      .task { if prisoner.value == nil { await load() } }
  }

  private func load() async {
    prisoner = .loading
    prisoner = await .from { try await app.container.directory.prisoner(id: id) }
    if let facilityId = prisoner.value?.facilityId { facilityDetail = try? await app.container.directory.facility(id: facilityId) }
  }

  private func content(_ p: Prisoner) -> some View {
    let facility = facilityDetail ?? p.facility
    return Screen(spacing: 10) {
      if let notice = p.statusNotice { AlertBanner("⚠ \(notice)") }
      if let photo = p.photoUrl.flatMap(URL.init(string:)) {
        AsyncImage(url: photo) { image in image.resizable().scaledToFill() } placeholder: { Theme.paperRaised }
          .frame(maxWidth: .infinity).frame(height: 240).clipShape(RoundedRectangle(cornerRadius: 4))
          .accessibilityLabel("Photo of \(p.name)")
      }
      Text(p.name).font(Theme.headline)
      let alsoKnown = [p.birthName].compactMap { $0 } + p.aliases
      if !alsoKnown.isEmpty { Muted(alsoKnown.joined(separator: "  ·  "), font: Theme.bodyLarge) }

      Button("Write a letter") { app.push(.compose(ComposeRequest(prisonerId: p.id))) }.buttonStyle(.primary)

      KeyValue("Country", p.country)
      if let f = facility {
        VStack(alignment: .leading, spacing: 2) {
          FieldLabel("Current facility")
          Button(f.name) { app.push(.facility(f.id)) }.buttonStyle(.link)
          ForEach(f.addressLines, id: \.self) { Text($0).font(Theme.bodyMedium) }
        }
        .padding(.vertical, 4)
      }
      KeyValue("Detained since", p.detainedSince.map(Format.longDay))
      KeyValue("Sentence", p.sentence)
      KeyValue("Est. release", p.releaseSummary)
      KeyValue("Charge(s)", p.charges)
      Muted(Format.verificationLine(p.verification.at), font: Theme.label)

      if let bio = p.bio { SectionTitle("About"); Text(bio).font(Theme.bodyLarge) }
      if !p.interests.isEmpty { SectionTitle("Interests"); TagRow(tags: p.interests) }

      if let f = facility {
        if !f.rules.isEmpty { SectionTitle("Facility mail rules"); MailRulesList(rules: f.rules, emptyText: "") }
        Muted("\(f.routing.label). \(f.routing.explanation)")
      }

      if let site = p.supportWebsite {
        SectionTitle("Support")
        if let url = URL(string: site) { Link("🔗 \(site)", destination: url).font(Theme.titleMedium) } else { Text(site) }
      }
      if let donation = p.donationInfo { SectionTitle("Donate / commissary"); Text(donation).font(Theme.bodyMedium) }

      if !p.supportGroups.isEmpty {
        SectionTitle("Support groups")
        ForEach(p.supportGroups) { g in
          VStack(alignment: .leading, spacing: 2) {
            Text(g.name).font(Theme.titleMedium)
            if let how = g.supportDescription { Text(how).font(Theme.bodyMedium) }
            Button("View group") { app.push(.group(g.id)) }.buttonStyle(.link)
          }
          .padding(.vertical, 6)
        }
      }
    }
  }
}

struct FacilityView: View {
  let app: AppModel
  let id: Int
  @State private var facility: Loadable<Facility> = .loading

  var body: some View {
    LoadableView(state: facility, retry: { Task { await load() } }) { f in content(f) }
      .navigationTitle(facility.value?.name ?? "Facility")
      .navigationBarTitleDisplayMode(.inline)
      .task { if facility.value == nil { await load() } }
  }

  private func load() async {
    facility = .loading
    facility = await .from { try await app.container.directory.facility(id: id) }
  }

  private func content(_ f: Facility) -> some View {
    Screen(spacing: 10) {
      if f.verification.isStale() { AlertBanner("⚠ This record has not been verified in over 6 months. Mail rules and routing details may have changed.") }
      Text(f.name).font(Theme.headline)
      if !f.shortLocation.isEmpty { Muted(f.shortLocation, font: Theme.bodyLarge) }

      if !f.addressLines.isEmpty {
        VStack(alignment: .leading, spacing: 2) {
          FieldLabel("Mailing address")
          Group {
            ForEach(f.addressLines, id: \.self) { Text($0) }
            if let country = f.country { Text(country) }
          }
          .font(Theme.bodyLarge).textSelection(.enabled)
        }
        .padding(.vertical, 4)
      }
      KeyValue("Routing", f.routing.label)
      Muted(f.routing.explanation)
      KeyValue("Scan service", f.scanService)
      KeyValue("Notes", f.notes)
      Muted(Format.verificationLine(f.verification.at), font: Theme.label)

      SectionTitle("Mail rules")
      MailRulesList(rules: f.rules, emptyText: "No rules recorded. Confirm with a support group before writing.")
      let explained = f.rules.rules.filter { !($0.description ?? "").isEmpty }
      if !explained.isEmpty {
        FieldLabel("What these mean").padding(.top, 6)
        ForEach(explained, id: \.tag) { Muted("\($0.label): \($0.description ?? "")") }
      }

      SectionTitle("Relay groups")
      if f.relayGroups.isEmpty { Muted("No relay group. Letters go directly to the facility.", font: Theme.bodyLarge) }
      ForEach(f.relayGroups) { g in
        Button(g.name + (g.location.isEmpty ? "" : " · \(g.location)")) { app.push(.group(g.id)) }.buttonStyle(.link)
      }

      SectionTitle("Prisoners currently held")
      if f.prisoners.isEmpty { Muted("None listed.", font: Theme.bodyLarge) }
      ForEach(f.prisoners) { p in
        Divider().overlay(Theme.rule)
        PrisonerRow(prisoner: p, horizontalPadding: 0) { app.push(.prisoner(p.id)) }
      }
    }
  }
}

struct GroupView: View {
  let app: AppModel
  let id: Int
  @State private var group: Loadable<SupportGroup> = .loading

  var body: some View {
    LoadableView(state: group, retry: { Task { await load() } }) { g in content(g) }
      .navigationTitle(group.value?.name ?? "Group")
      .navigationBarTitleDisplayMode(.inline)
      .task { if group.value == nil { await load() } }
  }

  private func load() async {
    group = .loading
    group = await .from { try await app.container.directory.group(id: id) }
  }

  private func links(_ g: SupportGroup) -> [(label: String, url: URL)] {
    var out: [(String, URL)] = []
    if let site = g.website, let url = URL(string: site) {
      out.append(("🔗 " + site.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: ""), url))
    }
    if let email = g.email, let url = URL(string: "mailto:\(email)") { out.append(("✉ \(email)", url)) }
    for (name, link) in g.socialLinks.sorted(by: { $0.key < $1.key }) {
      if let url = URL(string: link) { out.append((name.prefix(1).uppercased() + name.dropFirst(), url)) }
    }
    return out
  }

  private func content(_ g: SupportGroup) -> some View {
    Screen(spacing: 10) {
      if let announcement = g.announcement { AlertBanner(announcement) }
      Text(g.name).font(Theme.headline)
      if !g.location.isEmpty { Muted(g.location, font: Theme.bodyLarge) }

      ForEach(links(g), id: \.url) { Link($0.label, destination: $0.url).font(Theme.titleMedium).padding(.vertical, 4) }

      TagRow(tags: g.services.map(ServiceLabels.label))
      Muted(NetworkRoles.label(g.networkRole))

      if let about = g.about { SectionTitle("About"); Text(about).font(Theme.bodyLarge) }

      if !g.supportedPrisoners.isEmpty {
        SectionTitle("Prisoners we support")
        ForEach(g.supportedPrisoners) { p in
          Divider().overlay(Theme.rule)
          PrisonerRow(prisoner: p, horizontalPadding: 0) { app.push(.prisoner(p.id)) }
        }
      }
      if !g.relayPrisons.isEmpty {
        SectionTitle("Facilities we mail to")
        ForEach(g.relayPrisons) { f in
          Button(f.name + (f.shortLocation.isEmpty ? "" : " · \(f.shortLocation)")) { app.push(.facility(f.id)) }.buttonStyle(.link)
        }
      }
    }
  }
}
