@testable import ABCCore
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest

/// A directory photo is sent upright, square, small and bare (API #130, #151): the API strips the orientation tag
/// with the rest of the metadata and never re-encodes, so the phone has to do all of it.
final class PhotoPreparerTests: XCTestCase {
  /// A `width`×`height` picture, red on the left half and blue on the right, as a JPEG carrying `orientation`,
  /// a GPS position and a camera make, the way a phone camera writes one.
  private func photo(width: Int, height: Int, orientation: Int) throws -> Data {
    let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1); context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
    context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1); context.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
    let image = try XCTUnwrap(context.makeImage())
    let out = NSMutableData()
    let destination = try XCTUnwrap(CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil))
    let props: [CFString: Any] = [
      kCGImagePropertyOrientation: orientation,
      kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 52.2, kCGImagePropertyGPSLongitude: 21.0],
      kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "PhoneCo"],
    ]
    CGImageDestinationAddImage(destination, image, props as CFDictionary)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return out as Data
  }

  private func decode(_ data: Data) throws -> (image: CGImage, props: [CFString: Any]) {
    let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
    return (try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil)), (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:])
  }

  /// The colour at (x, y) from the top left, as (r, g, b) in 0…255.
  private func pixel(_ image: CGImage, _ x: Int, _ y: Int) throws -> (Int, Int, Int) {
    var bytes = [UInt8](repeating: 0, count: 4)
    let context = try XCTUnwrap(CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    context.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
    return (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]))
  }

  func testACameraPhotoComesOutSquareScaledAndWithNothingButThePixels() throws {
    let out = try PhotoPreparer.prepare(try photo(width: 4000, height: 3000, orientation: 1))
    let (image, props) = try decode(out)
    XCTAssertEqual([image.width, image.height], [1200, 1200])
    XCTAssertLessThanOrEqual(out.count, PhotoPreparer.maxBytes)
    XCTAssertNil(props[kCGImagePropertyGPSDictionary], "no place")
    XCTAssertNil((props[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFMake], "no camera")
    XCTAssertEqual(props[kCGImagePropertyOrientation] as? Int ?? 1, 1, "nothing left to rotate")
  }

  func testASidewaysPhotoIsTurnedUprightBeforeTheTagIsDropped() throws {
    // Stored 300×100 but tagged 6 ("rotate 90° clockwise to view"): upright it is 100 wide and 300 tall, with the
    // stored left half (red) on top. The centred square then has red above blue. Left untouched it would be red
    // on the left and blue on the right.
    let out = try PhotoPreparer.prepare(try photo(width: 300, height: 100, orientation: 6))
    let (image, _) = try decode(out)
    XCTAssertEqual([image.width, image.height], [100, 100], "a small picture is not scaled up")
    let top = try pixel(image, 50, 10), bottom = try pixel(image, 50, 90)
    XCTAssertTrue(top.0 > 200 && top.2 < 60, "top is red: \(top)")
    XCTAssertTrue(bottom.2 > 200 && bottom.0 < 60, "bottom is blue: \(bottom)")
  }

  func testWhatIsNotAPictureIsSaidToBeUnreadable() {
    XCTAssertThrowsError(try PhotoPreparer.prepare(Data("%PDF-1.7 not a picture".utf8))) { XCTAssertEqual($0 as? PhotoPreparer.Failure, .unreadable) }
  }
}
