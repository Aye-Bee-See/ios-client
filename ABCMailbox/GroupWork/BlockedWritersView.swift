import ABCCore
import Observation
import SwiftUI

/// The writers this group does not mail letters for (API #171), with Unblock, and what the group asked the
/// superadmins about a site-wide block and what they decided (API #172). Group admins only.
@MainActor @Observable
final class BlockedWritersModel {
  private(set) var blocks: Loadable<[WriterBlock]> = .loading
  private(set) var recommendations: [BanRecommendation]?
  private(set) var recommendationsFailed = false
  private(set) var busy = false

  @ObservationIgnored private let app: AppModel
  init(app: AppModel) { self.app = app }

  func load() async {
    blocks = await .from { try await app.container.group.blocks() }
    do { recommendations = try await app.container.group.banRecommendations(); recommendationsFailed = false } catch { recommendationsFailed = true }
  }

  func unblock(_ block: WriterBlock) async {
    busy = true
    defer { busy = false }
    do {
      let released = try await app.container.group.unblock(writerId: block.writerId)
      app.show("Unblocked. \(released) held letter\(released == 1 ? "" : "s") went back into the queue.")
      await load()
    } catch {
      app.show(AppError.from(error).userMessage ?? "The block could not be lifted.")
    }
  }
}

struct BlockedWritersView: View {
  @State private var model: BlockedWritersModel
  @State private var confirmUnblock: WriterBlock?

  init(app: AppModel) { _model = State(initialValue: BlockedWritersModel(app: app)) }

  var body: some View {
    LoadableView(state: model.blocks, retry: { Task { await model.load() } }) { blocks in
      Screen {
        Muted("Writers your group does not mail letters for. Each was told why. Lifting a block puts their held letters back in the queue.", font: Theme.bodyLarge)
        if blocks.isEmpty { EmptyBox("Your group has not blocked anyone.") }
        ForEach(blocks) { b in
          VStack(alignment: .leading, spacing: 4) {
            Text(b.writerName ?? "Writer \(b.writerId)").font(Theme.titleMedium)
            if let reason = b.reason { Text("Reason: \(reason)").font(Theme.bodyMedium) }
            Muted([b.blockedBy.map { "Blocked by \($0)" }, b.blockedAt.map { "on \(Format.long($0))" }].compactMap { $0 }.joined(separator: " "), font: Theme.label)
            Button("Unblock") { confirmUnblock = b }.buttonStyle(.link).disabled(model.busy)
          }
          .padding(.vertical, 6)
          Divider().overlay(Theme.rule)
        }

        SectionTitle("Site-wide block recommendations")
        Muted("What your group asked the superadmins, and what they decided.")
        if model.recommendationsFailed {
          ErrorText("The recommendations could not be loaded.")
        } else if let recs = model.recommendations {
          if recs.isEmpty { Muted("Your group has not recommended anyone.") }
          ForEach(recs) { r in
            VStack(alignment: .leading, spacing: 4) {
              Text(r.writerName ?? r.writerId.map { "Writer \($0)" } ?? "A writer").font(Theme.titleMedium)
              Muted(Self.state(r), font: Theme.bodyMedium)
              if let reason = r.reason { Text("Your group's reason: \(reason)").font(Theme.bodyMedium) }
              if let note = r.decisionNote { Text("The superadmin's note: \(note)").font(Theme.bodyMedium) }
            }
            .padding(.vertical, 6)
          }
        }
      }
    }
    .task { await model.load() }
    .refreshable { await model.load() }
    .confirmationDialog("Unblock \(confirmUnblock?.writerName ?? "this writer")?", isPresented: Binding(get: { confirmUnblock != nil }, set: { if !$0 { confirmUnblock = nil } }), titleVisibility: .visible) {
      Button("Unblock") { if let b = confirmUnblock { Task { await model.unblock(b) } } }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Your group will mail their letters again, and the ones it held go back into the queue. The writer is told.")
    }
    .navigationTitle("Blocked writers")
    .navigationBarTitleDisplayMode(.inline)
  }

  private static func state(_ r: BanRecommendation) -> String {
    switch r.status {
    case .pending: return r.recommendedAt.map { "Waiting for a superadmin since \(Format.long($0))" } ?? "Waiting for a superadmin"
    case .banned: return r.decidedAt.map { "Blocked everywhere on \(Format.long($0))" } ?? "Blocked everywhere"
    case .dismissed: return r.decidedAt.map { "Not blocked: decided on \(Format.long($0))" } ?? "Not blocked"
    }
  }
}
