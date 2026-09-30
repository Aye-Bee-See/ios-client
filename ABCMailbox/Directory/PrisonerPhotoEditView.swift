import ABCCore
import Observation
import PhotosUI
import SwiftUI

/// Adding, replacing or taking down a prisoner's photo (API #130, #166): a superadmin or any group admin of an
/// active group. The API does not check consent; this screen is where it is asked, worded by who is uploading
/// (decisions-made, 27 September). A group admin confirms the person agreed, since consent comes through the
/// group that knows them. A superadmin has no such relationship, but may take a photo from a public support page
/// the person's supporters published; they confirm that, and the credit names the page.
@MainActor @Observable
final class PrisonerPhotoEditModel {
  let prisonerId: Int
  let name: String
  let hasPhoto: Bool
  var credit: String
  var confirmed = false
  private(set) var prepared: Data?
  private(set) var preparing = false
  private(set) var busy = false
  private(set) var error: String?
  private(set) var fields = FormErrors()

  @ObservationIgnored private let app: AppModel

  init(app: AppModel, prisonerId: Int, name: String, hasPhoto: Bool, credit: String?) {
    self.app = app
    self.prisonerId = prisonerId
    self.name = name
    self.hasPhoto = hasPhoto
    self.credit = credit ?? ""
  }

  static let creditMax = 200
  var isSuperadmin: Bool { app.user?.isSuperadmin == true }
  var creditTrimmed: String { credit.trimmingCharacters(in: .whitespacesAndNewlines) }

  /// The first thing still needed, for under the disabled button.
  var missing: String? {
    if prepared == nil { return "Choose a photo." }
    if isSuperadmin, creditTrimmed.isEmpty { return "Say where the photo was published, in the credit." }
    if creditTrimmed.count > Self.creditMax { return "The credit can be at most \(Self.creditMax) characters." }
    if !confirmed { return isSuperadmin ? "Tick the box to confirm where the photo comes from." : "Tick the box to confirm \(name) has agreed." }
    return nil
  }

  var canUpload: Bool { !busy && !preparing && missing == nil }

  func picked(_ item: PhotosPickerItem?) async {
    guard let item else { return }
    preparing = true; error = nil; fields = FormErrors()
    defer { preparing = false }
    do {
      guard let raw = try await item.loadTransferable(type: Data.self) else { throw PhotoPreparer.Failure.unreadable }
      // Off the main thread: decoding a camera photo takes a moment.
      prepared = try await Task.detached(priority: .userInitiated) { try PhotoPreparer.prepare(raw) }.value
    } catch PhotoPreparer.Failure.tooLarge {
      prepared = nil; error = "That photo is too large even after shrinking it. Try a smaller one, or a screenshot of it."
    } catch {
      prepared = nil; self.error = "That file could not be read as a photo. Choose a JPEG, PNG or HEIC picture."
    }
  }

  func upload() async -> Bool {
    guard canUpload, let prepared else { return false }
    busy = true; error = nil; fields = FormErrors()
    defer { busy = false }
    do {
      try await app.container.directory.uploadPhoto(prisonerId: prisonerId, jpeg: prepared, credit: credit)
      return true
    } catch {
      fail(.from(error), else: "Could not upload the photo.")
      return false
    }
  }

  func remove() async -> Bool {
    busy = true; error = nil
    defer { busy = false }
    do {
      try await app.container.directory.removePhoto(prisonerId: prisonerId)
      return true
    } catch {
      fail(.from(error), else: "Could not take the photo down.")
      return false
    }
  }

  private func fail(_ e: AppError, else fallback: String) {
    if case .validation = e {
      fields = FormErrors(e, fields: ["photo": "photo", "credit": "credit"])
      error = fields.general
    } else {
      error = e == .network ? "Can't reach the server. Nothing has changed." : e.userMessage ?? fallback
    }
  }
}

struct PrisonerPhotoEditView: View {
  @State private var model: PrisonerPhotoEditModel
  @State private var item: PhotosPickerItem?
  @State private var confirmRemove = false
  private let app: AppModel

  init(app: AppModel, prisonerId: Int, name: String, hasPhoto: Bool, credit: String?) {
    self.app = app
    _model = State(initialValue: PrisonerPhotoEditModel(app: app, prisonerId: prisonerId, name: name, hasPhoto: hasPhoto, credit: credit))
  }

  var body: some View {
    Screen(spacing: 14, horizontal: 24) {
      Text("A photo on \(model.name)'s record is public wherever the record is. The phone crops it to a square and removes where and when it was taken, and the camera it came from, before it is sent.").font(Theme.bodyLarge)

      preview
      PhotosPicker(selection: $item, matching: .images) {
        Text(model.prepared == nil ? (model.hasPhoto ? "Choose a new photo" : "Choose a photo") : "Choose a different photo")
      }
      .buttonStyle(.outlineWide)
      if model.preparing { Muted("Preparing the photo…") }
      if let problem = model.fields.byField["photo"] { ErrorText(problem) }

      LabeledField(label: model.isSuperadmin ? "Credit" : "Credit (optional)",
                   hint: model.fields.byField["credit"] ?? (model.isSuperadmin ? "The public page the photo was published on, by the person's supporters." : "Shown beside the photo: where it came from, or whose permission it is there by."),
                   isError: model.fields.byField["credit"] != nil || model.creditTrimmed.count > PrisonerPhotoEditModel.creditMax) {
        TextField("", text: $model.credit, axis: .vertical).lineLimit(1...3)
      }

      CheckboxRow(text: model.isSuperadmin
        ? "This photo comes from a public support page that \(model.name)'s supporters published, and the credit names that page."
        : "\(model.name) has agreed to this photo going up in the public directory.", isOn: $model.confirmed)

      ErrorText(model.error)
      Button(model.busy ? "Uploading…" : (model.hasPhoto ? "Replace the photo" : "Add the photo")) {
        Task { if await model.upload() { done(model.hasPhoto ? "Photo replaced." : "Photo added.") } }
      }
      .buttonStyle(.primary).disabled(!model.canUpload).accessibilityIdentifier("photo-upload")
      if !model.busy, model.error == nil, let missing = model.missing { Muted(missing) }

      if model.hasPhoto {
        Divider().overlay(Theme.rule)
        Button("Take the photo down") { confirmRemove = true }.buttonStyle(.destructiveLink)
      }
    }
    .disabled(model.busy)
    .onChange(of: item) { _, new in Task { await model.picked(new) } }
    .confirmationDialog("Take the photo down?", isPresented: $confirmRemove, titleVisibility: .visible) {
      Button("Take it down", role: .destructive) { Task { if await model.remove() { done("Photo taken down.") } } }
    } message: {
      Text("It is removed from \(model.name)'s record and deleted from the server.")
    }
    .navigationTitle(model.hasPhoto ? "Change the photo" : "Add a photo")
    .navigationBarTitleDisplayMode(.inline)
  }

  @ViewBuilder private var preview: some View {
    if let data = model.prepared, let image = UIImage(data: data) {
      Image(uiImage: image).resizable().scaledToFit()
        .frame(maxWidth: 260).frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .accessibilityLabel("The photo as it will appear")
    }
  }

  private func done(_ message: String) {
    app.photoChanged()
    app.pop()
    app.show(message)
  }
}
