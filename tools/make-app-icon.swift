import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

// The app icon: the site's paper, a serif "ABC", and the red rule. 1024 px, no alpha (App Store requirement).
let size = 1024
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
func color(_ hex: UInt32) -> CGColor { CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1) }
func draw(_ string: String, font: String, size fontSize: CGFloat, kern: CGFloat, hex: UInt32, baseline: CGFloat) {
  let attributes: [NSAttributedString.Key: Any] = [
    NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(font as CFString, fontSize, nil),
    NSAttributedString.Key(kCTForegroundColorAttributeName as String): color(hex),
    NSAttributedString.Key(kCTKernAttributeName as String): kern,
  ]
  let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
  let width = CTLineGetTypographicBounds(line, nil, nil, nil) - Double(kern) // the last glyph's kern is not visible
  ctx.textPosition = CGPoint(x: (CGFloat(size) - CGFloat(width)) / 2, y: baseline)
  CTLineDraw(line, ctx)
}
ctx.setFillColor(color(0xF2F0ED)); ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
draw("ABC", font: "Georgia", size: 400, kern: -6, hex: 0x1A1A1A, baseline: 500)
ctx.setFillColor(color(0xB33A3A)); ctx.fill(CGRect(x: 150, y: 392, width: size - 300, height: 26))
draw("MAILBOX", font: "Georgia", size: 92, kern: 30, hex: 0x767676, baseline: 250)
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
precondition(CGImageDestinationFinalize(dest))
