import ABCCore
import SwiftUI

/// Deciding not to mail one letter or several (API #170): why, which of the facility's rules, and a few words to the
/// writer. Group admins only; a superadmin cannot decline, holding no key to read the letter. The words match Android.
struct DeclineSheet: View {
  let count: Int
  /// The rules a `facilityRule` decline may name: the letter's facility's, or for several letters those they all share.
  let rules: [MailRule]
  /// Several letters whose facilities have no rule in common.
  var noCommonRules = false
  let save: (DeclineReason, String?, String) async -> Bool

  @Environment(\.dismiss) private var dismiss
  @State private var reason: DeclineReason?
  @State private var rule: String?
  @State private var note = ""
  @State private var saving = false

  private var noteLength: Int { note.trimmingCharacters(in: .whitespacesAndNewlines).count }
  private var tooLong: Bool { noteLength > GroupRepository.returnNoteLimit }
  private var canSave: Bool {
    guard let reason, !tooLong, !saving else { return false }
    return reason != .facilityRule || rule != nil
  }

  var body: some View {
    NavigationStack {
      Screen {
        Muted("The writer is told it was not sent, and why, and can change it and send it again. It cannot be undone.", font: Theme.bodyLarge)
        SectionTitle("Why")
        ForEach(DeclineReason.allCases) { r in
          let unavailable = r == .facilityRule && rules.isEmpty
          Button { reason = r; if r != .facilityRule { rule = nil } } label: {
            HStack(spacing: 10) {
              Image(systemName: reason == r ? "largecircle.fill.circle" : "circle").foregroundStyle(reason == r ? Theme.red : Theme.inkMuted)
              Text(r.choice).font(Theme.bodyLarge).foregroundStyle(unavailable ? Theme.inkMuted : Theme.ink)
              Spacer()
            }
            .padding(.vertical, 6).contentShape(Rectangle())
          }
          .buttonStyle(.plain).disabled(unavailable)
          .accessibilityAddTraits(reason == r ? .isSelected : [])
        }
        if rules.isEmpty {
          Muted(noCommonRules ? "These letters go to facilities with no rule in common. To name a rule, decline them one at a time." : "No rules are recorded for this facility, so this reason cannot be chosen.")
        }
        if reason == .facilityRule, !rules.isEmpty {
          SectionTitle("Which rule")
          ForEach(rules, id: \.tag) { r in
            Button { rule = r.tag } label: {
              HStack(spacing: 10) {
                Image(systemName: rule == r.tag ? "largecircle.fill.circle" : "circle").foregroundStyle(rule == r.tag ? Theme.red : Theme.inkMuted)
                Text(r.label).font(Theme.bodyLarge).foregroundStyle(Theme.ink).multilineTextAlignment(.leading)
                Spacer()
              }
              .padding(.vertical, 4).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(rule == r.tag ? .isSelected : [])
          }
        }
        SectionTitle("A few words to the writer (optional)")
        TextField("", text: $note, axis: .vertical).lineLimit(2...4).font(Theme.bodyLarge)
          .padding(10).background(Theme.paperRaised, in: RoundedRectangle(cornerRadius: 4))
        Text("\(noteLength) of \(GroupRepository.returnNoteLimit). The writer reads this note, and it is not encrypted, even when letters are. Say why, and do not quote the letter.")
          .font(Theme.label).foregroundStyle(tooLong ? Theme.red : Theme.inkMuted)
        Button(saving ? "Saving…" : "Don't send it") {
          guard let reason else { return }
          Task { saving = true; if await save(reason, rule, note) { dismiss() }; saving = false }
        }
        .buttonStyle(.primary).disabled(!canSave).accessibilityIdentifier("declineConfirm")
      }
      .navigationTitle(count == 1 ? "Don't send this letter" : "Don't send \(count) letters")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
    }
  }
}
