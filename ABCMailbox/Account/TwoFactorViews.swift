import ABCCore
import CoreImage.CIFilterBuiltins
import Observation
import SwiftUI
import UIKit

// Two-factor sign-in on one's own account (API #173, #175): the settings page, the set-up steps it shares with the
// screen shown when it is required, and the recovery codes. The secret and the codes are never kept on the phone.

/// Setting it up: a fresh secret for the authenticator app, then the first code from it, which switches it on.
/// The recovery codes go to `onCodes`; whoever shows this shows them, so they stay up until saved.
@MainActor @Observable
final class TwoFactorSetupModel {
  var code = ""
  private(set) var setup: TwoFactorSetup?
  private(set) var busy = false
  private(set) var error: String?
  /// Opening the link found no authenticator app on this phone.
  var noApp = false

  @ObservationIgnored private let app: AppModel
  @ObservationIgnored private let onCodes: ([String]) -> Void

  init(app: AppModel, onCodes: @escaping ([String]) -> Void) {
    self.app = app
    self.onCodes = onCodes
  }

  var canConfirm: Bool { !busy && setup != nil && TwoFactorCode.isWellFormed(code) }

  func edited() { error = nil }

  /// Asking again replaces the secret being set up, so starting over is always possible.
  func start() async {
    busy = true; error = nil; noApp = false
    defer { busy = false }
    do {
      setup = try await app.container.twoFactor.setup()
      code = ""
    } catch {
      let e = AppError.from(error)
      // Switched on meanwhile, from another device: nothing to set up.
      if e.conflictCondition == "enabled" { onCodes([]) } else { self.error = Self.message(e) }
    }
  }

  func confirm() async {
    guard canConfirm else { return }
    busy = true; error = nil
    defer { busy = false }
    do {
      let codes = try await app.container.twoFactor.confirm(code: code)
      code = ""
      onCodes(codes)
    } catch {
      let e = AppError.from(error)
      if e.conflictCondition == "enabled" {
        // Switched on meanwhile, from another device: nothing to confirm, and its codes were shown there.
        onCodes([])
      } else if case .validation = e {
        self.error = "That code is not right. Check the app shows this account, and type the code it shows now."
      } else {
        self.error = Self.message(e)
      }
    }
  }

  static func message(_ e: AppError) -> String {
    e == .network ? "Can't reach the server. Check your connection and try again." : e.userMessage ?? "Something went wrong. Please try again."
  }
}

/// The steps themselves: start, add the account to the app (open, scan or type), type its first code.
struct TwoFactorSetupSteps: View {
  @Bindable var model: TwoFactorSetupModel
  @Environment(\.openURL) private var openURL
  @State private var copied = false

  var body: some View {
    if let setup = model.setup { adding(setup) } else {
      Text("Sign in with your password and a six-digit code from an authenticator app on your phone. Someone who learns your password still cannot sign in without the code.").font(Theme.bodyLarge)
      Muted("Any authenticator app works, such as Aegis, 2FAS or Ente Auth. You also get ten recovery codes, for if you lose the phone.")
      ErrorText(model.error)
      Button(model.busy ? "Starting…" : "Set up two-factor sign-in") { Task { await model.start() } }
        .buttonStyle(.primary).disabled(model.busy).accessibilityIdentifier("two-factor-start")
    }
  }

  @ViewBuilder private func adding(_ setup: TwoFactorSetup) -> some View {
    SectionTitle("1. Add this account to your authenticator app")
    Text("If the app is on this phone, open it from here. Otherwise scan the code with it, or type the key.").font(Theme.bodyMedium)
    if let url = URL(string: setup.otpauthUri) {
      Button("Open in authenticator app") { openURL(url) { model.noApp = !$0 } }
        .buttonStyle(.outlineWide).accessibilityIdentifier("two-factor-open-app")
    }
    if model.noApp { ErrorText("No app on this phone opens it. Install an authenticator app, or type the key below into one.") }
    Muted("Or scan this with an authenticator app on another device:")
    if let image = QRCode.image(setup.otpauthUri) {
      Image(uiImage: image).interpolation(.none).resizable().scaledToFit()
        .frame(width: 200, height: 200).padding(12).background(.white, in: RoundedRectangle(cornerRadius: 6))
        .frame(maxWidth: .infinity)
        .accessibilityLabel("QR code for your authenticator app")
    }
    Muted("Or type this key into the app:")
    Text(Self.grouped(setup.secret))
      .font(.system(.body, design: .monospaced)).textSelection(.enabled)
      .frame(maxWidth: .infinity).padding(12).background(Theme.paperRaised, in: RoundedRectangle(cornerRadius: 6))
      .accessibilityLabel(setup.secret.map(String.init).joined(separator: " "))
    Button(copied ? "Copied" : "Copy the key") {
      Clipboard.copySecret(setup.secret)
      copied = true
    }
    .buttonStyle(.link)

    SectionTitle("2. Type the code the app shows")
    LabeledField(label: "Six-digit code", isError: model.error != nil) {
      TextField("123456", text: $model.code)
        .font(Theme.mono).textContentType(.oneTimeCode).keyboardType(.numberPad)
        .accessibilityIdentifier("two-factor-confirm-code")
    }
    ErrorText(model.error)
    Button(model.busy ? "Checking…" : "Switch on") { Task { await model.confirm() } }
      .buttonStyle(.primary).disabled(!model.canConfirm).accessibilityIdentifier("two-factor-confirm")
      .onChange(of: model.code) { model.edited() }
  }

  /// In fours, as authenticator apps show a key to type.
  static func grouped(_ secret: String) -> String {
    stride(from: 0, to: secret.count, by: 4).map { i in
      let start = secret.index(secret.startIndex, offsetBy: i)
      return String(secret[start..<(secret.index(start, offsetBy: 4, limitedBy: secret.endIndex) ?? secret.endIndex)])
    }.joined(separator: " ")
  }
}

/// The recovery codes, shown once. Not left without ticking the box: the caller hides every other way out.
struct TwoFactorRecoveryCodesView: View {
  let codes: [String]
  let onSaved: () -> Void
  @State private var saved = false
  @State private var copied = false

  var body: some View {
    Text("Save your recovery codes").font(Theme.headlineSmall)
    Text("If you lose your phone, each of these signs you in once instead of a code. They are shown only now. Write them on paper or put them in a password manager, not only on this phone.").font(Theme.bodyLarge)
    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
      ForEach(codes, id: \.self) { code in
        Text(code).font(.system(.body, design: .monospaced)).textSelection(.enabled)
          .accessibilityLabel(code.map(String.init).joined(separator: " "))
      }
    }
    .padding(.vertical, 16).frame(maxWidth: .infinity)
    .background(Theme.paperRaised, in: RoundedRectangle(cornerRadius: 6))
    .accessibilityIdentifier("two-factor-codes")
    Button(copied ? "Copied" : "Copy the codes") {
      Clipboard.copySecret(codes.joined(separator: "\n"))
      copied = true
    }
    .buttonStyle(.outline)
    CheckboxRow(text: "I have saved these codes somewhere safe.", isOn: $saved).accessibilityIdentifier("two-factor-codes-saved")
    Button("Continue", action: onSaved).buttonStyle(.primary).disabled(!saved).accessibilityIdentifier("two-factor-codes-done")
  }
}

/// Required for this account and not set up (API #175): over everything, since nothing else works until it is.
/// The way out is signing out; the way on is setting it up. Starting over is always possible: asking for a new
/// secret replaces the one being set up.
@MainActor @Observable
final class TwoFactorRequiredModel {
  private(set) var because: [String] = []
  /// Set once it is on: the codes to save, or none when it was switched on meanwhile from another device.
  fileprivate(set) var codes: [String]?
  private(set) var signingOut = false
  @ObservationIgnored private(set) var setup: TwoFactorSetupModel!
  @ObservationIgnored private let app: AppModel

  init(app: AppModel) {
    self.app = app
    setup = TwoFactorSetupModel(app: app) { [weak self] codes in self?.codes = codes }
  }

  func load() async {
    guard let status = try? await app.container.twoFactor.status() else { return }
    because = status.requiredBecause
    // Set up meanwhile on another device, or no longer required: the server refuses nothing now, so neither does the app.
    if codes == nil, status.enabled || !status.required { await app.sessions.twoFactorSetUp() }
  }

  func signOut() async {
    signingOut = true
    defer { signingOut = false }
    try? await app.sessions.logout()
  }
}

struct TwoFactorRequiredView: View {
  private let app: AppModel
  @State private var model: TwoFactorRequiredModel

  init(app: AppModel) {
    self.app = app
    _model = State(initialValue: TwoFactorRequiredModel(app: app))
  }

  var body: some View {
    Screen(spacing: 16, horizontal: 24) {
      Text("Two-factor sign-in").font(Theme.headline).padding(.top, 20)
      if let codes = model.codes {
        if codes.isEmpty {
          Text("Two-factor sign-in is on already.").font(Theme.bodyLarge)
          Button("Continue") { Task { await app.sessions.twoFactorSetUp() } }.buttonStyle(.primary)
        } else {
          TwoFactorRecoveryCodesView(codes: codes) { Task { await app.sessions.twoFactorSetUp() } }
        }
      } else {
        AlertBanner("\(TwoFactorCode.requiredBy(model.because)) requires two-factor sign-in. Set it up to go on; nothing else works until you do.")
          .accessibilityIdentifier("two-factor-required")
        TwoFactorSetupSteps(model: model.setup)
        if model.setup.setup != nil {
          Button("Start again") { Task { await model.setup.start() } }.buttonStyle(.link).disabled(model.setup.busy)
        }
        Divider().overlay(Theme.rule)
        Button("Sign out") { Task { await model.signOut() } }.buttonStyle(.outlineWide).disabled(model.signingOut)
      }
    }
    .background(Theme.paper.ignoresSafeArea())
    .task { await model.load() }
  }
}

/// The settings page: on or off, the codes left, fresh codes, and switching it off where that is allowed.
@MainActor @Observable
final class TwoFactorSettingsModel {
  private(set) var status: Loadable<TwoFactorStatus> = .loading
  /// Codes just made, on screen until the box is ticked: the page hides its way back and the tabs meanwhile.
  private(set) var codes: [String]?
  private(set) var busy = false
  private(set) var error: String?
  var asking: Ask?
  var typed = ""

  enum Ask { case newCodes, switchOff }

  @ObservationIgnored private let app: AppModel
  @ObservationIgnored private(set) var setup: TwoFactorSetupModel!

  init(app: AppModel) {
    self.app = app
    setup = TwoFactorSetupModel(app: app) { [weak self] codes in self?.madeCodes(codes) }
  }

  func load() async {
    status = await .from { try await app.container.twoFactor.status() }
    // On, or not required: a set-up screen still up from earlier (on another device, or a requirement lifted) goes.
    if codes == nil, let s = status.value, s.enabled || !s.required, app.sessions.twoFactorSetupRequired { await app.sessions.twoFactorSetUp() }
  }

  private func madeCodes(_ codes: [String]) {
    if codes.isEmpty { Task { await load() } } else { self.codes = codes }
  }

  func codesSaved() async {
    codes = nil
    await app.sessions.twoFactorSetUp()
    setup = TwoFactorSetupModel(app: app) { [weak self] codes in self?.madeCodes(codes) }
    await load()
  }

  func ask(_ what: Ask) { typed = ""; error = nil; asking = what }

  func answer() async {
    guard let what = asking else { return }
    let typed = typed.trimmingCharacters(in: .whitespaces)
    asking = nil
    busy = true; error = nil
    defer { busy = false }
    do {
      switch what {
      case .newCodes:
        codes = try await app.container.twoFactor.newRecoveryCodes(code: typed)
      case .switchOff:
        // Six digits are a code from the app; anything else is a recovery code.
        if TwoFactorCode.isWellFormed(typed) { try await app.container.twoFactor.disable(code: typed) } else { try await app.container.twoFactor.disable(recoveryCode: typed) }
        app.show("Two-factor sign-in is off.")
        await load()
      }
    } catch {
      let e = AppError.from(error)
      switch e {
      case .validation where e.fieldProblems.first?.field == "recoveryCode": self.error = "That recovery code is not right, or was used already."
      case .validation: self.error = "That code is not right. Check the app shows this account, and type the code it shows now."
      case .conflict where e.conflictCondition == "required": self.error = "It is required for your account, so it cannot be switched off."; await load()
      default: self.error = TwoFactorSetupModel.message(e)
      }
    }
  }
}

struct TwoFactorSettingsView: View {
  @State private var model: TwoFactorSettingsModel
  private let app: AppModel

  init(app: AppModel) {
    self.app = app
    _model = State(initialValue: TwoFactorSettingsModel(app: app))
  }

  var body: some View {
    @Bindable var model = model
    LoadableView(state: model.status, retry: { Task { await model.load() } }) { status in
      Screen(spacing: 16, horizontal: 24) {
        if let codes = model.codes {
          TwoFactorRecoveryCodesView(codes: codes) { Task { await model.codesSaved() } }
        } else if status.enabled {
          on(status)
        } else {
          if status.required { AlertBanner("\(TwoFactorCode.requiredBy(status.requiredBecause)) requires two-factor sign-in.") }
          TwoFactorSetupSteps(model: model.setup)
        }
      }
    }
    .disabled(model.busy)
    .navigationTitle("Two-factor sign-in")
    .navigationBarTitleDisplayMode(.inline)
    .navigationBarBackButtonHidden(model.codes != nil)
    .toolbar(model.codes != nil ? .hidden : .automatic, for: .tabBar)
    .task { await model.load() }
    .alert(model.asking == .switchOff ? "Switch off two-factor sign-in" : "New recovery codes", isPresented: Binding(get: { model.asking != nil }, set: { if !$0 { model.asking = nil } })) {
      TextField(model.asking == .switchOff ? "Code or recovery code" : "Six-digit code", text: $model.typed)
        .textContentType(.oneTimeCode).autocorrectionDisabled().textInputAutocapitalization(.characters)
      Button("Cancel", role: .cancel) {}
      Button(model.asking == .switchOff ? "Switch off" : "Make new codes", role: model.asking == .switchOff ? .destructive : nil) { Task { await model.answer() } }
    } message: {
      Text(model.asking == .switchOff
        ? "Type a code from your authenticator app, or one of your recovery codes. After this your password alone signs you in."
        : "Type a code from your authenticator app. Your current recovery codes stop working.")
    }
  }

  @ViewBuilder private func on(_ status: TwoFactorStatus) -> some View {
    Text(status.enabledAt.map { "On since \(Format.long($0))" } ?? "On").font(Theme.titleLarge).accessibilityIdentifier("two-factor-on")
    Text("Signing in takes your password and a six-digit code from your authenticator app.").font(Theme.bodyLarge)
    Muted(status.recoveryCodesLeft == 1 ? "1 recovery code left." : "\(status.recoveryCodesLeft) recovery codes left.")
    ErrorText(model.error)
    Button("New recovery codes…") { model.ask(.newCodes) }.buttonStyle(.link)
    if status.required {
      Muted("It is required for your account, so it cannot be switched off.")
    } else {
      Button("Switch off") { model.ask(.switchOff) }.buttonStyle(.destructiveLink).accessibilityIdentifier("two-factor-off")
    }
  }
}

enum QRCode {
  static func image(_ text: String) -> UIImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(text.utf8)
    filter.correctionLevel = "M"
    guard let out = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
          let cg = CIContext().createCGImage(out, from: out.extent) else { return nil }
    return UIImage(cgImage: cg)
  }
}

enum Clipboard {
  /// Local only, so it is not offered to the person's other devices, and gone in ten minutes.
  static func copySecret(_ text: String) {
    UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: text]], options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(600)])
  }
}
