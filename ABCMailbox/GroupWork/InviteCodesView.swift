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
  private(set) var groupName = "Your group"
  var count = 10
  var label = ""
  private(set) var busy = false
  private(set) var error: String?
  /// The slips as a PDF file, for printing or sharing.
  private(set) var pdf: URL?

  @ObservationIgnored private let app: AppModel
  init(app: AppModel) { self.app = app }

  var canIssue: Bool { !busy && (1...50).contains(count) && label.count <= 80 }

  func load() async {
    if let id = app.user?.chapterId, let group = try? await app.container.directory.group(id: id) { groupName = group.name }
    let fresh: Loadable<InviteCodeQuota> = await .from { try await self.app.container.group.inviteCodes() }
    if fresh.value != nil || quota.value == nil { quota = fresh }
  }

  func issue() async {
    guard canIssue else { return }
    busy = true; error = nil
    defer { busy = false }
    do {
      let batch = try await app.container.group.issueInviteCodes(count: count, label: label, days: nil)
      issued = batch
      pdf = try? InviteSlips.pdf(batch, groupName: groupName)
      label = ""
      await load()
    } catch {
      self.error = AppError.from(error).userMessage ?? "Could not issue the codes."
    }
  }

  func cancel(_ batch: InviteCodeBatch?) async {
    busy = true; error = nil
    defer { busy = false }
    do {
      let n = try await app.container.group.cancelInviteCodes(batch: batch?.id)
      app.show(n == 0 ? "Nothing to cancel." : "\(Format.plural(n, "code")) cancelled. Accounts already made with this batch stay.")
      if batch == nil || batch?.id == issued?.batch { issued = nil; pdf = nil }
      await load()
    } catch {
      self.error = AppError.from(error).userMessage ?? "Could not cancel the codes."
    }
  }

  /// Leaving the screen is the end of the codes: they cannot be shown again.
  func forgetIssued() { issued = nil; if let pdf { try? FileManager.default.removeItem(at: pdf) }; pdf = nil }
}

struct InviteCodesView: View {
  @State private var model: InviteCodesModel
  @State private var confirmCancel: InviteCodeBatch?
  @State private var confirmCancelAll = false
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
    .onDisappear { model.forgetIssued() }
    .confirmationDialog(confirmCancel.map { "Cancel the unused codes of \"\($0.label ?? "this batch")\"?" } ?? "", isPresented: Binding(get: { confirmCancel != nil }, set: { if !$0 { confirmCancel = nil } }), titleVisibility: .visible) {
      Button("Cancel them", role: .destructive) { if let b = confirmCancel { Task { await model.cancel(b) } } }
      Button("Keep them", role: .cancel) {}
    } message: {
      Text("Slips from this batch that were not used stop working. Accounts already made with them stay.")
    }
    .confirmationDialog("Cancel every unused code?", isPresented: $confirmCancelAll, titleVisibility: .visible) {
      Button("Cancel them all", role: .destructive) { Task { await model.cancel(nil) } }
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
        Button("Print") { InviteSlips.print(pdf) }.buttonStyle(.primaryCompact).accessibilityIdentifier("printSlips")
        ShareLink(item: pdf) { Text("Share as PDF") }.buttonStyle(.outline)
      }
    }
    ForEach(issued.codes, id: \.self) { code in
      HStack(spacing: 14) {
        if let qr = InviteSlips.qr(InviteCode.webLink(code)) { Image(uiImage: qr).resizable().interpolation(.none).frame(width: 56, height: 56).accessibilityHidden(true) }
        VStack(alignment: .leading, spacing: 2) {
          Text(InviteCode.pretty(code)).font(Theme.mono)
          Muted(model.groupName, font: Theme.caption)
        }
      }
      .padding(10).frame(maxWidth: .infinity, alignment: .leading)
      .background(Theme.paperRaised, in: RoundedRectangle(cornerRadius: 4))
    }
    Button("Done, put them away") { model.forgetIssued() }.buttonStyle(.outlineWide)
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
        ("Your invite code for ABC Mailbox. In the app: Sign in, \"I have an invite code\". Or scan the square." as NSString).draw(in: CGRect(x: box.minX + pad, y: box.minY + pad + 64, width: box.width - 170, height: 40), withAttributes: [.font: small])
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
    controller.present(animated: true)
  }
}
