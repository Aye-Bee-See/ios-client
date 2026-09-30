import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Readies a directory photo for upload (API #130, #151). The API strips all metadata, and with it the orientation
/// tag, so a picture must already be upright; it never re-encodes, so what is sent is what people see. So here the
/// camera's orientation is applied, the picture cropped to a centred square (the directory shows it in a square),
/// scaled to at most `side` pixels, and written as a JPEG with no metadata at all: no place, time or camera.
public enum PhotoPreparer {
  public static let side = 1200
  /// `PHOTO_MAX_BYTES` on the API: 5 MiB.
  public static let maxBytes = 5 * 1024 * 1024

  public enum Failure: Error, Equatable {
    /// Not an image this phone can read.
    case unreadable
    /// Would not come under the size limit even at low quality.
    case tooLarge
  }

  public static func prepare(_ data: Data, side: Int = side, maxBytes: Int = maxBytes) throws -> Data {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
          let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int,
          width > 0, height > 0
    else { throw Failure.unreadable }

    // The thumbnail's size limit is on its long side; ask for one whose short side comes out at `side`.
    let long = max(width, height), short = min(width, height)
    let wanted = min(long, Int((Double(side) * Double(long) / Double(short)).rounded(.up)))
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true, // applies the orientation tag
      kCGImageSourceThumbnailMaxPixelSize: wanted,
    ]
    guard let upright = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw Failure.unreadable }

    let edge = min(upright.width, upright.height)
    let crop = CGRect(x: (upright.width - edge) / 2, y: (upright.height - edge) / 2, width: edge, height: edge)
    guard let square = upright.cropping(to: crop) else { throw Failure.unreadable }

    for quality in [0.85, 0.75, 0.6, 0.45] {
      let out = NSMutableData()
      guard let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { throw Failure.unreadable }
      // Only the compression; no properties are copied, so nothing but the pixels leaves the phone.
      CGImageDestinationAddImage(destination, square, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
      guard CGImageDestinationFinalize(destination) else { throw Failure.unreadable }
      if out.length <= maxBytes { return out as Data }
    }
    throw Failure.tooLarge
  }
}
