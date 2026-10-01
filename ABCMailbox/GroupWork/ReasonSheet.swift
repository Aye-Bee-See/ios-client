import ABCCore
import SwiftUI

/// A required reason, for blocking a writer or recommending a site-wide block (API #171, #172). `text` and `help`
/// say who reads it, which is the point: the writer reads a block's reason, only a superadmin a recommendation's.
struct ReasonSheet: View {
  let title: String
  let text: String
  let help: String
  let limit: Int
  let confirm: String
  let save: (String) async -> Bool

  @Environment(\.dismiss) private var dismiss
  @State private var reason = ""
  @State private var saving = false

  private var length: Int { reason.trimmingCharacters(in: .whitespacesAndNewlines).count }
  private var canSave: Bool { length > 0 && length <= limit && !saving }

  var body: some View {
    NavigationStack {
      Screen {
        Muted(text, font: Theme.bodyLarge)
        SectionTitle("Reason")
        TextField("", text: $reason, axis: .vertical).lineLimit(3...8).font(Theme.bodyLarge)
          .padding(10).background(Theme.paperRaised, in: RoundedRectangle(cornerRadius: 4))
        Text("\(length) of \(limit). \(help)").font(Theme.label).foregroundStyle(length > limit ? Theme.red : Theme.inkMuted)
        Button(saving ? "Saving…" : confirm) {
          Task { saving = true; if await save(reason) { dismiss() }; saving = false }
        }
        .buttonStyle(.primary).disabled(!canSave)
      }
      .navigationTitle(title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
    }
  }
}
