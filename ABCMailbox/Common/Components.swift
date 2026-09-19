import ABCCore
import SwiftUI

/// Loading / failed / loaded for a single record.
enum Loadable<Value> {
  case loading
  case failed(AppError)
  case loaded(Value)

  var value: Value? { if case .loaded(let v) = self { return v } else { return nil } }

  /// Runs `work` and becomes its outcome.
  static func from(_ work: () async throws -> Value) async -> Loadable {
    do { return .loaded(try await work()) } catch { return .failed(.from(error)) }
  }
}

/// A scrolling page with the site's margins. Most detail and form screens are one of these.
struct Screen<Content: View>: View {
  var spacing: CGFloat = 12
  var horizontal: CGFloat = 20
  @ViewBuilder var content: () -> Content

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: spacing, content: content)
        .padding(.horizontal, horizontal).padding(.vertical, 12)
        .frame(maxWidth: 700, alignment: .leading) // a readable measure on an iPad
        .frame(maxWidth: .infinity)
    }
    .scrollDismissesKeyboard(.interactively)
    .background(Theme.paper)
  }
}

struct SearchField: View {
  @Binding var text: String
  let placeholder: String

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass").foregroundStyle(Theme.inkMuted)
      TextField(placeholder, text: $text)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .submitLabel(.search)
      if !text.isEmpty {
        Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.inkMuted) }
          .accessibilityLabel("Clear search")
      }
    }
    .padding(.horizontal, 12).padding(.vertical, 10)
    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.rule, lineWidth: 1))
  }
}

/// One row of mutually exclusive filter chips; nil is "All".
struct ChipRow<Value: Hashable>: View {
  let options: [(value: Value, label: String)]
  @Binding var selected: Value?
  var allLabel = "All"
  var showAll = true

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        if showAll { chip(allLabel, isOn: selected == nil) { selected = nil } }
        ForEach(options, id: \.value) { option in
          chip(option.label, isOn: selected == option.value) { selected = (selected == option.value && showAll) ? nil : option.value }
        }
      }
      .padding(.vertical, 2)
    }
  }

  private func chip(_ label: String, isOn: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(label)
        .font(Theme.bodyMedium.weight(.medium))
        .foregroundStyle(isOn ? Theme.red : Theme.ink)
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(isOn ? Theme.redWash : .clear, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(isOn ? Theme.red.opacity(0.4) : Theme.rule, lineWidth: 1))
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(isOn ? .isSelected : [])
  }
}

/// A small rounded label, like the interest tags on the site.
struct Tag: View {
  let text: String
  var body: some View {
    Text(text)
      .font(Theme.label)
      .foregroundStyle(Theme.inkMuted)
      .padding(.horizontal, 8).padding(.vertical, 4)
      .background(Theme.paperRaised, in: RoundedRectangle(cornerRadius: 4))
  }
}

struct TagRow: View {
  let tags: [String]
  var body: some View {
    if !tags.isEmpty {
      FlowLayout(spacing: 6) { ForEach(tags, id: \.self) { Tag(text: $0) } }
    }
  }
}

/// Lays children out left to right and wraps to the next line, like words in a paragraph.
struct FlowLayout: Layout {
  var spacing: CGFloat = 6

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let arranged = arrange(subviews, width: proposal.width ?? .infinity)
    // Claim the whole width on offer, not just what the tags need. Measuring and placing then happen at
    // the same width, so they always agree on where the lines break. Claiming only the tags' own width
    // goes wrong by a fraction of a pixel: SwiftUI rounds that width before placing, the last tag no
    // longer fits, and it wraps onto a line whose height was never reserved (the row below draws over it).
    let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? arranged.size.width
    return CGSize(width: width, height: arranged.size.height)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    for (index, origin) in arrange(subviews, width: bounds.width).origins.enumerated() {
      subviews[index].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
    }
  }

  private func arrange(_ subviews: Subviews, width: CGFloat) -> (origins: [CGPoint], size: CGSize) {
    var origins: [CGPoint] = [], x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      // Half a point of tolerance, so a rounding difference never decides a line break.
      if x > 0, x + size.width > width + 0.5 { x = 0; y += rowHeight + spacing; rowHeight = 0 }
      origins.append(CGPoint(x: x, y: y))
      x += size.width + spacing
      rowHeight = max(rowHeight, size.height)
      widest = max(widest, x - spacing)
    }
    return (origins, CGSize(width: widest, height: y + rowHeight))
  }
}

/// The red-wash notice used for status notices and stale-verification warnings.
struct AlertBanner: View {
  let text: String
  init(_ text: String) { self.text = text }
  var body: some View {
    Text(text)
      .font(Theme.bodyMedium)
      .foregroundStyle(Theme.red)
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Theme.redWash, in: RoundedRectangle(cornerRadius: 4))
  }
}

struct SectionTitle: View {
  let text: String
  init(_ text: String) { self.text = text }
  var body: some View {
    Text(text).font(Theme.titleLarge).padding(.top, 8).accessibilityAddTraits(.isHeader)
  }
}

struct FieldLabel: View {
  let text: String
  init(_ text: String) { self.text = text }
  var body: some View { Text(text.uppercased()).font(Theme.label).foregroundStyle(Theme.inkMuted) }
}

struct KeyValue: View {
  let label: String
  let value: String?
  init(_ label: String, _ value: String?) { self.label = label; self.value = value }
  var body: some View {
    if let value, !value.trimmingCharacters(in: .whitespaces).isEmpty {
      VStack(alignment: .leading, spacing: 2) {
        FieldLabel(label)
        Text(value).font(Theme.bodyLarge)
      }
      .padding(.vertical, 4)
      .accessibilityElement(children: .combine)
    }
  }
}

struct Muted: View {
  let text: String
  var font = Theme.bodyMedium
  init(_ text: String, font: Font = Theme.bodyMedium) { self.text = text; self.font = font }
  var body: some View { Text(text).font(font).foregroundStyle(Theme.inkMuted) }
}

struct ErrorText: View {
  let text: String?
  init(_ text: String?) { self.text = text }
  var body: some View {
    if let text { Text(text).font(Theme.bodyMedium).foregroundStyle(Theme.red) }
  }
}

/// A tappable list row with a title, a subtitle, and optional tags.
struct RecordRow: View {
  let title: String
  var secondary: String?
  var subtitle: String?
  var notice: String?
  var tags: [String] = []
  var horizontalPadding: CGFloat = 20
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 4) {
        if let notice { Text(notice).font(Theme.label).foregroundStyle(Theme.red) }
        Text(title).font(Theme.titleMedium).foregroundStyle(Theme.ink)
        if let secondary { Muted(secondary) }
        if let subtitle { Text(subtitle).font(Theme.bodyMedium).foregroundStyle(Theme.ink) }
        TagRow(tags: tags)
      }
      .multilineTextAlignment(.leading)
      .padding(.horizontal, horizontalPadding).padding(.vertical, 12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

struct LoadingBox: View {
  var body: some View { ProgressView().frame(maxWidth: .infinity).padding(24) }
}

struct ErrorBox: View {
  let error: AppError
  let retry: () -> Void
  var body: some View {
    VStack(spacing: 12) {
      Text(error.readable).font(Theme.bodyMedium).foregroundStyle(Theme.red).multilineTextAlignment(.center)
      Button("Try again", action: retry).buttonStyle(.primaryCompact)
    }
    .frame(maxWidth: .infinity).padding(24)
  }
}

struct EmptyBox: View {
  let text: String
  init(_ text: String) { self.text = text }
  var body: some View { Muted(text, font: Theme.bodyLarge).multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(24) }
}

/// A single record that loads, fails with a retry, or shows.
struct LoadableView<Value, Content: View>: View {
  let state: Loadable<Value>
  let retry: () -> Void
  @ViewBuilder var content: (Value) -> Content

  var body: some View {
    switch state {
    case .loading: VStack { LoadingBox(); Spacer() }.frame(maxWidth: .infinity).background(Theme.paper)
    case .failed(let error): VStack { ErrorBox(error: error, retry: retry); Spacer() }.frame(maxWidth: .infinity).background(Theme.paper)
    case .loaded(let value): content(value)
    }
  }
}

/// A facility's mail rules as a bulleted list, tags first, then page and photo limits and languages.
struct MailRulesList: View {
  let rules: MailRules
  let emptyText: String

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      if rules.isEmpty, !emptyText.isEmpty { Muted(emptyText) }
      ForEach(rules.lines(), id: \.self) { line in
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Text("•")
          Text(line)
        }
        .font(Theme.bodyMedium)
        .accessibilityElement(children: .combine)
      }
    }
  }
}

/// A list over `PagedLoader` with the three states every list needs: first load (spinner or
/// error), empty, and "loading more" at the bottom. The `header` holds search and filter
/// chips so they scroll with the list. Pull down to refresh.
struct PagedList<Item: Identifiable & Sendable, Header: View, Row: View>: View {
  let loader: PagedLoader<Item>
  let emptyText: String
  @ViewBuilder var header: () -> Header
  @ViewBuilder var row: (Item) -> Row

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 0) {
        header()
        switch loader.phase {
        case .loadingFirst: LoadingBox()
        case .failedFirst(let error): ErrorBox(error: error) { Task { await loader.refresh() } }
        default: if loader.isEmpty { EmptyBox(emptyText) }
        }
        ForEach(loader.items) { item in
          row(item).onAppear { Task { await loader.loadMoreIfNeeded(current: item) } }
          Divider().overlay(Theme.rule)
        }
        switch loader.phase {
        case .loadingMore: LoadingBox()
        case .failedMore(let error): ErrorBox(error: error) { Task { await loader.loadMore() } }
        default: EmptyView()
        }
      }
      .frame(maxWidth: 700, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
    .scrollDismissesKeyboard(.interactively)
    .refreshable { await loader.refresh() }
    .background(Theme.paper)
  }
}

/// An outlined text field with its label above and a hint below, after the site's forms.
struct LabeledField<Field: View>: View {
  let label: String
  var hint: String?
  var isError = false
  /// False when the content is more than one control and names its own parts (the password box).
  var namesField = true
  @ViewBuilder var field: () -> Field

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      // The visible label is decoration for VoiceOver: the field itself is announced by this name.
      Text(label).font(Theme.bodyMedium.weight(.medium)).foregroundStyle(isError ? Theme.red : Theme.ink).accessibilityHidden(true)
      named(field())
        .padding(.horizontal, 12).padding(.vertical, 11)
        .background(Theme.paperRaised, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(isError ? Theme.red : Theme.rule, lineWidth: 1))
      if let hint { Text(hint).font(Theme.label).foregroundStyle(isError ? Theme.red : Theme.inkMuted) }
    }
  }

  @ViewBuilder private func named(_ field: Field) -> some View {
    if namesField { field.accessibilityLabel(label) } else { field }
  }
}

/// A password box with the site's Show / Hide toggle. One toggle can drive several fields.
struct PasswordField: View {
  let label: String
  @Binding var text: String
  @Binding var show: Bool
  var hint: String?
  var isError = false
  var isNew = false
  var showsToggle = true
  var onSubmit: () -> Void = {}

  var body: some View {
    LabeledField(label: label, hint: hint, isError: isError, namesField: false) {
      HStack {
        Group {
          if show { TextField("", text: $text) } else { SecureField("", text: $text) }
        }
        .accessibilityLabel(label)
        .textContentType(isNew ? .newPassword : .password)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .onSubmit(onSubmit)
        if showsToggle {
          Button(show ? "Hide" : "Show") { show.toggle() }.font(Theme.bodyMedium.weight(.medium)).foregroundStyle(Theme.red)
            .accessibilityLabel(show ? "Hide password" : "Show password")
        }
      }
    }
  }
}

/// A claim token or recovery code, large and monospaced, grouped in fours for reading aloud.
struct SecretCodeDisplay: View {
  let pretty: String

  var body: some View {
    let groups = pretty.split(separator: "-").map(String.init)
    let lines = stride(from: 0, to: groups.count, by: 3).map { groups[$0..<min($0 + 3, groups.count)].joined(separator: "-") }
    Text(lines.joined(separator: "\n"))
      .font(.system(.title2, design: .monospaced)) // follows the reader's text size
      .lineSpacing(10)
      .multilineTextAlignment(.center)
      .textSelection(.enabled)
      .frame(maxWidth: .infinity)
      .padding(.vertical, 20)
      .background(Theme.paperRaised, in: RoundedRectangle(cornerRadius: 6))
      .accessibilityLabel(pretty.map(String.init).joined(separator: " "))
  }
}

/// A row that is one checkbox with its sentence: tapping the sentence ticks the box, and
/// VoiceOver hears one control with its label.
struct CheckboxRow: View {
  let text: String
  @Binding var isOn: Bool

  var body: some View {
    Button { isOn.toggle() } label: {
      HStack(alignment: .top, spacing: 12) {
        Image(systemName: isOn ? "checkmark.square.fill" : "square").font(.title3).foregroundStyle(isOn ? Theme.ink : Theme.inkMuted)
        Text(text).font(Theme.bodyMedium).foregroundStyle(Theme.ink).multilineTextAlignment(.leading)
      }
      .padding(.vertical, 8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(isOn ? .isSelected : [])
  }
}

/// A larger text box with a placeholder, which `TextEditor` does not have on its own.
struct TextBox: View {
  @Binding var text: String
  let placeholder: String
  var minHeight: CGFloat = 220

  var body: some View {
    ZStack(alignment: .topLeading) {
      if text.isEmpty { Text(placeholder).foregroundStyle(Theme.inkMuted).padding(.horizontal, 5).padding(.vertical, 8).allowsHitTesting(false) }
      TextEditor(text: $text).scrollContentBackground(.hidden).frame(minHeight: minHeight)
    }
    .font(Theme.bodyLarge)
    .padding(8)
    .background(Theme.paperRaised, in: RoundedRectangle(cornerRadius: 6))
    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.rule, lineWidth: 1))
  }
}
