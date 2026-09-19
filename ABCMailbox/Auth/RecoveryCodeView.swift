import ABCCrypto
import SwiftUI
import UIKit

/// Shown exactly once, right after keys are created or an account is claimed.
/// The code is the only way back in if the password is lost, and nobody else
/// has it, so the screen cannot be left without ticking the box: it is not a
/// sheet and has no back button, so there is no gesture that dismisses it.
struct RecoveryCodeView: View {
  let code: String
  let onSaved: () -> Void
  @State private var saved = false
  @State private var copied = false

  var body: some View {
    Screen(spacing: 16, horizontal: 24) {
      Text("Save your recovery code").font(Theme.headline).padding(.top, 20)
      Text("Your letters are encrypted with a key only you hold. Your password unlocks it. If you ever forget the password, this code is the only other way in. We cannot see it and cannot send it to you again.").font(Theme.bodyLarge)
      SecretCodeDisplay(pretty: SecretCodes.pretty(code)).accessibilityIdentifier("recovery-code")
      Button(copied ? "Copied" : "Copy") {
        // Local only, so the code is not offered to the user's other devices, and gone in ten minutes.
        UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: SecretCodes.pretty(code)]], options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(600)])
        copied = true
      }
      .buttonStyle(.outline)
      AlertBanner("Write it on paper or put it in a password manager. Do not keep it only on this phone, and do not send it to anyone.")
      CheckboxRow(text: "I have saved this code somewhere safe.", isOn: $saved).accessibilityIdentifier("recovery-saved")
      Button("Continue", action: onSaved).buttonStyle(.primary).disabled(!saved).accessibilityIdentifier("recovery-continue")
    }
    .background(Theme.paper.ignoresSafeArea())
  }
}
