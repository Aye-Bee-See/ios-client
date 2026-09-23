import ABCCore
import PhotosUI
import SwiftUI
import UIKit

/// After `new-letter.html`: the facility's rules above the editor, a character
/// and page count, an optional private note to the relay group, attachments,
/// and the relay-group picker only when the facility has more than one.
struct ComposeView: View {
  @State private var model: ComposeModel
  @State private var pickingFile = false
  @State private var takingPhoto = false
  @State private var pickedPhoto: PhotosPickerItem?
  @Environment(\.scenePhase) private var scenePhase
  private let app: AppModel

  init(app: AppModel, request: ComposeRequest) {
    self.app = app
    _model = State(initialValue: ComposeModel(app: app, request: request))
  }

  var body: some View {
    Group {
      if app.user == nil {
        VStack(alignment: .leading, spacing: 12) {
          Text("Sign in to write a letter.").font(Theme.bodyLarge)
          Button("Sign in") { app.signIn() }.buttonStyle(.primaryCompact)
          Spacer()
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading).background(Theme.paper)
      } else if model.loading {
        VStack { LoadingBox(); Spacer() }.frame(maxWidth: .infinity).background(Theme.paper)
      } else {
        form
      }
    }
    .navigationTitle(model.title)
    .navigationBarTitleDisplayMode(.inline)
    .task(id: app.user?.id) { if app.user != nil { await model.load() } }
    .onDisappear { model.flushDraft() }
    .onChange(of: scenePhase) { if scenePhase != .active { model.flushDraft() } }
    .fileImporter(isPresented: $pickingFile, allowedContentTypes: model.allowedTypes) { result in
      if case .success(let url) = result { model.attach(documentAt: url) }
    }
    .fullScreenCover(isPresented: $takingPhoto) {
      CameraPicker { image in model.attach(image: image, name: "\(model.recordingReply ? "reply" : "photo")-\(Int(Date().timeIntervalSince1970)).jpg") }.ignoresSafeArea()
    }
    .onChange(of: pickedPhoto) {
      guard let item = pickedPhoto else { return }
      pickedPhoto = nil
      Task {
        if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
          model.attach(image: image, name: "photo-\(Int(Date().timeIntervalSince1970)).jpg")
        } else {
          model.error = "Could not read that photo."
        }
      }
    }
  }

  private var form: some View {
    Screen {
      if let p = model.prisoner {
        Text(model.recordingReply ? "From: \(p.name)" : "To: \(p.name)").font(Theme.titleLarge)
        if let who = model.writingAs { Text("Writing as: \(who)").font(Theme.bodyMedium).foregroundStyle(Theme.red) }
        if let why = model.startedFrom { Muted(why) }
        if model.recordingReply { Muted("Type what the prisoner wrote, attach a scan or a photo of the letter, or both. The writer will see it in their thread.") }
        if let f = model.facility { Muted(f.name + (f.shortLocation.isEmpty ? "" : ", \(f.shortLocation)"), font: Theme.bodyLarge) }
      }

      if !model.recordingReply {
        if let f = model.facility {
          SectionTitle("Facility rules · \(f.name)")
          MailRulesList(rules: f.rules, emptyText: "No rules recorded for this facility. Confirm with a support group before writing.")
        }
        RelaySection(relay: model.relay, selected: $model.selectedRelay)
      }
      if model.canBeOnPaper { paperSection }

      TextBox(text: $model.body, placeholder: model.recordingReply ? "Type the prisoner's letter here, if you are transcribing it." : model.onPaper ? "Optional: type what the letter says, if you want a copy here." : "Write your letter here. Paragraph breaks will be preserved when printed.")
      if !model.onPaper { Muted("\(model.characters) characters · ~\(Format.plural(model.pages, "page"))", font: Theme.label) }

      // What the rules mean for this particular letter: warnings in red, the rest as notes.
      if !model.recordingReply {
        if !model.onPaper {
          ForEach(model.advice, id: \.text) { a in
            if a.warning { AlertBanner("⚠ \(a.text)") } else { Muted(a.text) }
          }
        }
        noteSection
      }

      attachmentsSection
      ErrorText(model.error)

      Button(model.sendLabel) { Task { await model.send() } }.buttonStyle(.primary).disabled(!model.canSend)
      if model.onPaper {
        Muted("Nothing is printed. Hand the letter to your relay group; it goes out with their next batch, and a reply will come back to this conversation.")
      } else if !model.recordingReply {
        Muted("Your letter won't be sent immediately. It goes to your relay group's queue, where they will print and physically mail it on your behalf.")
      }
    }
    .disabled(model.sending)
  }

  /// API PR #118: a letter written by hand and handed to the group. The record is what a reply comes back to.
  @ViewBuilder private var paperSection: some View {
    Toggle(isOn: $model.onPaper) {
      VStack(alignment: .leading, spacing: 2) {
        Text("This letter is on paper").font(Theme.bodyLarge)
        Muted("You wrote it by hand and are handing it to your relay group to mail. Nothing is printed; a photo of the page is optional.", font: Theme.label)
      }
    }
    .tint(Theme.red)
    .accessibilityIdentifier("onPaper")
  }

  // No note to a relay group on a reply: it is not being mailed anywhere.
  @ViewBuilder private var noteSection: some View {
    if model.showNote {
      VStack(alignment: .leading, spacing: 4) {
        Text("Note to relay group").font(Theme.bodyMedium.weight(.medium))
        TextBox(text: $model.note, placeholder: "Optional. Only your relay group will see this.", minHeight: 70)
        Muted("Not sent to the prisoner. Use it for context about the letter or its origin.", font: Theme.label)
      }
    } else {
      Button("+ Add a note to relay group") { model.showNote = true }.buttonStyle(.link)
    }
  }

  @ViewBuilder private var attachmentsSection: some View {
    SectionTitle("Attachments")
    ForEach(model.attachments) { file in
      HStack {
        Text("📎 \(file.name)").font(Theme.bodyMedium)
        Spacer()
        Button("Remove") { model.remove(file) }.buttonStyle(.link)
      }
    }
    FlowLayout(spacing: 8) {
      Button(model.imagesAllowed ? "Attach a file" : "Attach a PDF") { pickingFile = true }.buttonStyle(.outline)
      if model.imagesAllowed {
        // On an iPhone, pictures live in Photos rather than Files.
        PhotosPicker(selection: $pickedPhoto, matching: .images) { Text("Choose a photo") }.buttonStyle(.outline)
        // The phone's camera is the natural scanner for a handwritten letter or a prisoner's reply.
        if UIImagePickerController.isSourceTypeAvailable(.camera) {
          Button("Take a photo") { takingPhoto = true }.buttonStyle(.outline)
        }
      }
    }
    Muted(model.onPaper ? "A photo of the page, if you want a copy here. It can also be added later, from the conversation, until the group mails the letter." : "PDF, JPG, PNG, or WebP · max 20 MB. A scan of a handwritten letter works well.", font: Theme.label)
  }
}

private struct RelaySection: View {
  let relay: RelayChoice
  @Binding var selected: Int?

  var body: some View {
    switch relay {
    case .automatic(let group):
      Text("Relayed by \(group.name)" + (group.location.isEmpty ? "" : " (\(group.location))")).font(Theme.bodyMedium)
    case .direct:
      Muted("Mailed directly to the facility.")
    case .blocked(let reason):
      AlertBanner("⚠ \(reason)")
    case .choose(let options, let required):
      VStack(alignment: .leading, spacing: 4) {
        SectionTitle("Relay group")
        Muted(required ? "This facility only accepts relayed mail. Choose which group to route through." : "\(options.count) groups relay to this facility. Choose one, or leave it to the group.")
        ForEach(options) { g in radio(g.name, detail: g.location.isEmpty ? nil : g.location, isOn: selected == g.id) { selected = g.id } }
        if !required { radio("Let the network decide", detail: nil, isOn: selected == nil) { selected = nil } }
      }
    }
  }

  private func radio(_ title: String, detail: String?, isOn: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack(spacing: 10) {
        Image(systemName: isOn ? "largecircle.fill.circle" : "circle").foregroundStyle(isOn ? Theme.ink : Theme.inkMuted)
        VStack(alignment: .leading) {
          Text(title).font(Theme.bodyLarge).foregroundStyle(Theme.ink)
          if let detail { Muted(detail) }
        }
        Spacer()
      }
      .padding(.vertical, 6).contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(isOn ? .isSelected : [])
  }
}

/// The system camera. SwiftUI has no camera view of its own, so this wraps UIKit's.
struct CameraPicker: UIViewControllerRepresentable {
  let onImage: (UIImage) -> Void
  @Environment(\.dismiss) private var dismiss

  func makeUIViewController(context: Context) -> UIImagePickerController {
    let picker = UIImagePickerController()
    picker.sourceType = .camera
    picker.delegate = context.coordinator
    return picker
  }

  func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}
  func makeCoordinator() -> Coordinator { Coordinator(self) }

  final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    private let parent: CameraPicker
    init(_ parent: CameraPicker) { self.parent = parent }

    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
      if let image = info[.originalImage] as? UIImage { parent.onImage(image) }
      parent.dismiss()
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
  }
}
