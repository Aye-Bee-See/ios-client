import SwiftUI
import UIKit

/// The web site's tokens (style.css): a paper-like off-white, near-black text,
/// one red used for rules, alerts and emphasis, and a warm grey for borders.
/// Dark: the same relationships inverted, with a slightly lifted red for contrast.
/// The app should look like the site, on either platform.
enum Theme {
  static let paper = dynamic(light: 0xF2F0ED, dark: 0x161514)
  static let paperRaised = dynamic(light: 0xFFFFFF, dark: 0x211F1D)
  static let ink = dynamic(light: 0x1A1A1A, dark: 0xEDEAE5)
  static let inkMuted = dynamic(light: 0x767676, dark: 0x9A958E)
  static let rule = dynamic(light: 0xD4D0CA, dark: 0x3A3733)
  static let red = dynamic(light: 0xB33A3A, dark: 0xD9625F)
  static let redWash = dynamic(light: 0xFDF0F0, dark: 0x3A1F1F)

  // Serif for headings, as on the site (Georgia there; the system serif, New York, here), the
  // default sans for everything read at length. All of them follow the reader's text size setting.
  static let display = Font.system(.largeTitle, design: .serif)
  static let headline = Font.system(.title, design: .serif)
  static let headlineSmall = Font.system(.title2, design: .serif)
  static let titleLarge = Font.system(.title3, design: .serif).weight(.medium)
  static let titleMedium = Font.body.weight(.medium)
  static let bodyLarge = Font.body
  static let bodyMedium = Font.subheadline
  static let caption = Font.caption
  static let label = Font.caption2.weight(.medium)
  static let mono = Font.system(.body, design: .monospaced)

  private static func dynamic(light: UInt32, dark: UInt32) -> Color {
    Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
  }

  /// Bars in the paper colour with a serif title, so pushed screens match the rest.
  static func applyAppearance() {
    let serif = UIFontDescriptor.preferredFontDescriptor(withTextStyle: .headline).withDesign(.serif)
    let nav = UINavigationBarAppearance()
    nav.configureWithOpaqueBackground()
    nav.backgroundColor = UIColor(paper)
    nav.shadowColor = UIColor(rule)
    if let serif { nav.titleTextAttributes = [.font: UIFont(descriptor: serif, size: 0)] }
    UINavigationBar.appearance().standardAppearance = nav
    UINavigationBar.appearance().scrollEdgeAppearance = nav
    UINavigationBar.appearance().compactAppearance = nav

    let bar = UITabBarAppearance()
    bar.configureWithOpaqueBackground()
    bar.backgroundColor = UIColor(paperRaised)
    bar.shadowColor = UIColor(rule)
    UITabBar.appearance().standardAppearance = bar
    UITabBar.appearance().scrollEdgeAppearance = bar
  }
}

private extension UIColor {
  convenience init(hex: UInt32) {
    self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
  }
}

/// The dark, full-width button the site uses for the main action of a page.
struct PrimaryButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled
  var fullWidth = true

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(Theme.titleMedium)
      .foregroundStyle(Theme.paper)
      .padding(.vertical, 13).padding(.horizontal, 20)
      .frame(maxWidth: fullWidth ? .infinity : nil)
      .background(Theme.ink.opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.35), in: RoundedRectangle(cornerRadius: 6))
  }
}

struct OutlineButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled
  var fullWidth = false

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(Theme.titleMedium)
      .foregroundStyle(Theme.ink.opacity(isEnabled ? 1 : 0.4))
      .padding(.vertical, 12).padding(.horizontal, 18)
      .frame(maxWidth: fullWidth ? .infinity : nil)
      .background(configuration.isPressed ? Theme.rule.opacity(0.4) : .clear, in: RoundedRectangle(cornerRadius: 6))
      .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.rule, lineWidth: 1))
  }
}

/// Text that acts as a link: red, no chrome.
struct LinkButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled
  var color: Color = Theme.red

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(Theme.titleMedium)
      .foregroundStyle(color.opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.4))
      .padding(.vertical, 6)
      .contentShape(Rectangle())
  }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
  static var primary: PrimaryButtonStyle { PrimaryButtonStyle() }
  static var primaryCompact: PrimaryButtonStyle { PrimaryButtonStyle(fullWidth: false) }
}

extension ButtonStyle where Self == OutlineButtonStyle {
  static var outline: OutlineButtonStyle { OutlineButtonStyle() }
  static var outlineWide: OutlineButtonStyle { OutlineButtonStyle(fullWidth: true) }
}

extension ButtonStyle where Self == LinkButtonStyle {
  static var link: LinkButtonStyle { LinkButtonStyle() }
  static var destructiveLink: LinkButtonStyle { LinkButtonStyle(color: Theme.red) }
  static var quietLink: LinkButtonStyle { LinkButtonStyle(color: Theme.ink) }
}
