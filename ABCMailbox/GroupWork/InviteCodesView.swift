import ABCCore
import CoreImage.CIFilterBuiltins
import Observation
import SwiftUI
import UIKit

/// Invite codes (API PR #116): the chapter prints slips for a letter night, sees how much of its quota is in use,
/// and cancels what it did not hand out. The codes are shown once, here; the server keeps only their hashes.
@MainActor @Observable
final class InviteCodesModel {
  private(set) var quota: Loadable<InviteCodeQuota> = .loading
  /// The batch just issued: its codes exist on this screen and nowhere else.
  private(set) var issued: IssuedInviteCodes?
  /// The chapter's name, which goes on every slip: nil until the directory has answered, and issuing waits for it.
  private(set) var groupName: String?
  /// The slips were printed or shared: they exist on paper now, and forgetting them is right. Until then, leaving
  /// them behind would leave live codes nobody can show again, so the screen asks whether to cancel the batch.
  private(set) var handedOff = false
  var count = 10
  var label = ""
  private(set) var busy = false
  private(set) var error: String?
  /// The slips as a PDF file, for printing or sharing.
  private(set) var pdf: URL?

  @ObservationIgnored private let app: AppModel
  init(app: AppModel) { self.app = app }

  var canIssue: Bool { !busy && groupName != nil && (1...50).contains(count) && label.count <= 80 }

  func load() async {
    if groupName == nil, let id = app.user?.chapterId {
      do { groupName = try await app.container.directory.group(id: id).name } catch {
        self.error = "Could not read your group's name from the directory, which goes on every slip. Check the connection and pull to try again."
      }
    }
    let fresh: Loadable<InviteCodeQuota> = await .from { try await self.app.container.group.inviteCodes() }
    if fresh.value != nil || quota.value == nil { quota = fresh }
  }

  func issue() async {
    guard canIssue else { return }
    busy = true; error = nil
    defer { busy = false }
    guard let groupName else { return }
    do {
      let batch = try await app.container.group.issueInviteCodes(count: count, label: label, days: nil)
      issued = batch
      handedOff = false
      pdf = try? InviteSlips.pdf(batch, groupName: groupName)
      label = ""
      await load()
    } catch {
      self.error = AppError.from(error).userMessage ?? "Could not issue the codes."
    }
  }

  /// Cancels the unused codes of one batch, or of every batch when `batchId` is nil.
  func cancel(batchId: String?) async {
    busy = true; error = nil
    defer { busy = false }
    do {
      let n = try await app.container.group.cancelInviteCodes(batch: batchId)
      app.show(n == 0 ? "Nothing to cancel." : "\(Format.plural(n, "code")) cancelled. Accounts already made with this batch stay.")
      if batchId == nil || batchId == issued?.batch { issued = nil; pdf = nil }
      await load()
    } catch {
      self.error = AppError.from(error).userMessage ?? "Could not cancel the codes."
    }
  }

  func noteHandedOff() { handedOff = true }

  /// The end of the codes on this phone: they cannot be shown again.
  func forgetIssued() { issued = nil; if let pdf { try? FileManager.default.removeItem(at: pdf) }; pdf = nil }

  /// The batch was neither printed nor shared: cancel it, so no live code is left that nobody can show.
  func cancelUnshown() async {
    guard let issued else { return }
    await cancel(batchId: issued.batch)
  }
}

struct InviteCodesView: View {
  @State private var model: InviteCodesModel
  @State private var confirmCancel: InviteCodeBatch?
  @State private var confirmCancelAll = false
  @State private var confirmDone = false
  private let app: AppModel

  init(app: AppModel) {
    self.app = app
    _model = State(initialValue: InviteCodesModel(app: app))
  }

  var body: some View {
    Screen(spacing: 12, horizontal: 24) {
      if let issued = model.issued { slips(issued) } else { issueForm }
      Divider().overlay(Theme.rule)
      quotaSection
    }
    .disabled(model.busy)
    .navigationTitle("Invite codes")
    .navigationBarTitleDisplayMode(.inline)
    .task { await model.load() }
    .refreshable { await model.load() }
    .onDisappear { model.forgetIssued() }
    .confirmationDialog("These slips were not printed or shared", isPresented: $confirmDone, titleVisibility: .visible) {
      Button("Cancel this batch", role: .destructive) { Task { await model.cancelUnshown(); model.forgetIssued() } }
      Button("Keep the codes") { model.forgetIssued() }
      Button("Go back", role: .cancel) {}
    } message: {
      Text("Put away, they cannot be shown again. Kept, they stay live and count against your quota until they expire or you cancel them from the list below.")
    }
    .confirmationDialog(confirmCancel.map { "Cancel the unused codes of \"\($0.label ?? "this batch")\"?" } ?? "", isPresented: Binding(get: { confirmCancel != nil }, set: { if !$0 { confirmCancel = nil } }), titleVisibility: .visible) {
      Button("Cancel them", role: .destructive) { if let b = confirmCancel { Task { await model.cancel(batchId: b.id) } } }
      Button("Keep them", role: .cancel) {}
    } message: {
      Text("Slips from this batch that were not used stop working. Accounts already made with them stay.")
    }
    .confirmationDialog("Cancel every unused code?", isPresented: $confirmCancelAll, titleVisibility: .visible) {
      Button("Cancel them all", role: .destructive) { Task { await model.cancel(batchId: nil) } }
      Button("Keep them", role: .cancel) {}
    } message: {
      Text("Every slip not yet used stops working. Accounts already made with them stay.")
    }
  }

  @ViewBuilder private var issueForm: some View {
    Text("Print slips for a letter night, or for anyone your group vouches for. A newcomer types the code into the app and the account is theirs from the start: your group vouches, and never sees what they write.").font(Theme.bodyLarge)
    Muted("Your group sees counts only. The server keeps no link between a code and the account it made.")
    Stepper("Codes to print: \(model.count)", value: $model.count, in: 1...50).font(Theme.bodyLarge)
    LabeledField(label: "Label (optional)", hint: "So the list says which slips these were: \"Letter night, 2 October\".", isError: model.label.count > 80) {
      TextField("", text: $model.label)
    }
    ErrorText(model.error)
    Button(model.busy ? "Printing…" : "Print \(Format.plural(model.count, "code"))") { Task { await model.issue() } }
      .buttonStyle(.primary).disabled(!model.canIssue).accessibilityIdentifier("issueCodes")
  }

  /// The codes, once. Each slip: the code in fours, the group's name, the date, the QR that opens the app.
  @ViewBuilder private func slips(_ issued: IssuedInviteCodes) -> some View {
    AlertBanner("These codes are shown once. Print or share the slips now: when you leave this screen they cannot be shown again, only cancelled.")
    if let expires = issued.expiresAt { Text("Use by \(Format.long(expires))").font(Theme.titleMedium) }
    HStack(spacing: 16) {
      if let pdf = model.pdf {
        Button("Print") { model.noteHandedOff(); InviteSlips.print(pdf) }.buttonStyle(.primaryCompact).accessibilityIdentifier("printSlips")
        ShareLink(item: pdf) { Text("Share as PDF") }.buttonStyle(.outline).simultaneousGesture(TapGesture().onEnded { model.noteHandedOff() })
      }
    }
    ForEach(issued.codes, id: \.self) { code in
      HStack(spacing: 14) {
        if let qr = InviteSlips.qr(InviteCode.webLink(code)) { Image(uiImage: qr).resizable().interpolation(.none).frame(width: 56, height: 56).accessibilityHidden(true) }
        VStack(alignment: .leading, spacing: 2) {
          Text(InviteCode.pretty(code)).font(Theme.mono)
          Muted(model.groupName ?? "", font: Theme.caption)
        }
      }
      .padding(10).frame(maxWidth: .infinity, alignment: .leading)
      .background(Theme.paperRaised, in: RoundedRectangle(cornerRadius: 4))
    }
    Button("Done, put them away") { if model.handedOff { model.forgetIssued() } else { confirmDone = true } }.buttonStyle(.outlineWide)
  }

  @ViewBuilder private var quotaSection: some View {
    switch model.quota {
    case .loading: LoadingBox()
    case .failed(let error): ErrorBox(error: error) { Task { await model.load() } }
    case .loaded(let q):
      SectionTitle("Codes in use")
      Text("\(q.outstanding) of \(q.limit) unused codes out. A used code frees its place at once; an unused one counts until it expires or you cancel it.").font(Theme.bodyMedium)
      if q.batches.isEmpty { Muted("No batches yet.") }
      ForEach(q.batches) { b in
        VStack(alignment: .leading, spacing: 2) {
          Text(b.label ?? "Batch \(b.id)").font(Theme.titleMedium)
          Muted([b.createdAt.map { "Printed \(Format.short($0))" }, b.expiresAt.map { "use by \(Format.short($0))" }].compactMap { $0 }.joined(separator: " · "), font: Theme.caption)
          Muted("\(b.used) used · \(b.unused) unused · \(b.cancelled) cancelled · \(b.expired) expired")
          if b.unused > 0 { Button("Cancel unused") { confirmCancel = b }.buttonStyle(.destructiveLink) }
        }
        .padding(.vertical, 6)
      }
      if q.outstanding > 0 { Button("Cancel every unused code") { confirmCancelAll = true }.buttonStyle(.destructiveLink) }
    }
  }
}

/// The slips on paper: four to a US-letter page, each with the code, the group, the date and a QR that opens the app.
enum InviteSlips {
  static func qr(_ text: String) -> UIImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(text.utf8)
    filter.correctionLevel = "M"
    guard let image = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)), let cg = CIContext().createCGImage(image, from: image.extent) else { return nil }
    return UIImage(cgImage: cg)
  }

  static func pdf(_ issued: IssuedInviteCodes, groupName: String) throws -> URL {
    let page = CGRect(x: 0, y: 0, width: 612, height: 792)
    let renderer = UIGraphicsPDFRenderer(bounds: page)
    let useBy = issued.expiresAt.map { "Use by \(Format.long($0))" } ?? ""
    let data = renderer.pdfData { ctx in
      let perPage = 4, slipHeight = (page.height - 72) / CGFloat(perPage)
      for (i, code) in issued.codes.enumerated() {
        if i % perPage == 0 { ctx.beginPage() }
        let top = 36 + CGFloat(i % perPage) * slipHeight
        let box = CGRect(x: 36, y: top + 8, width: page.width - 72, height: slipHeight - 16)
        UIColor.lightGray.setStroke(); UIBezierPath(rect: box).stroke()
        let pad: CGFloat = 20
        if let qr = qr(InviteCode.webLink(code)) { qr.draw(in: CGRect(x: box.maxX - pad - 110, y: box.minY + (box.height - 110) / 2, width: 110, height: 110)) }
        let mono = UIFont.monospacedSystemFont(ofSize: 26, weight: .semibold), body = UIFont.systemFont(ofSize: 13), small = UIFont.systemFont(ofSize: 11)
        (groupName as NSString).draw(at: CGPoint(x: box.minX + pad, y: box.minY + pad), withAttributes: [.font: body])
        (InviteCode.pretty(code) as NSString).draw(at: CGPoint(x: box.minX + pad, y: box.minY + pad + 24), withAttributes: [.font: mono])
        ("Your invite code for letters.support. In the app: Sign in, \"I have an invite code\". Or scan the square." as NSString).draw(in: CGRect(x: box.minX + pad, y: box.minY + pad + 64, width: box.width - 170, height: 40), withAttributes: [.font: small])
        (useBy as NSString).draw(at: CGPoint(x: box.minX + pad, y: box.maxY - pad - 14), withAttributes: [.font: small])
      }
    }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("invite-slips-\(issued.batch).pdf")
    try data.write(to: url, options: [.atomic, .completeFileProtection])
    return url
  }

  static func print(_ pdf: URL) {
    let info = UIPrintInfo(dictionary: nil)
    info.jobName = "Invite slips"
    let controller = UIPrintInteractionController.shared
    controller.printInfo = info
    controller.printingItem = pdf
    // An iPad shows the panel as a popover, which needs somewhere to point; an iPhone shows a sheet (as PrintLetter does).
    let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
    if UIDevice.current.userInterfaceIdiom == .pad, let view = window?.rootViewController?.view {
      controller.present(from: CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1), in: view, animated: true)
    } else {
      controller.present(animated: true)
    }
  }
}
