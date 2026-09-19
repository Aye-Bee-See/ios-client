import Foundation
import UniformTypeIdentifiers

/// A file the user picked, copied into our cache so we can upload it later.
public struct StagedFile: Equatable, Identifiable, Sendable {
  public let url: URL
  public let name: String
  public let mimeType: String
  public let size: Int
  public var id: URL { url }
  public var isImage: Bool { mimeType.hasPrefix("image/") }
}

/// Files on this device: staging a picked document for upload and keeping
/// downloaded attachments. The document picker hands back a security-scoped
/// URL whose read permission is temporary, so the bytes are copied immediately.
/// Both directories are in Caches: the system may empty them, and they are never backed up.
public final class LocalFiles: Sendable {
  private let root: URL

  public init(root: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]) { self.root = root }

  private func directory(_ name: String) -> URL {
    let dir = root.appendingPathComponent(name, isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  private func safe(_ name: String) -> String { name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_") }

  /// Copies a document the user chose in the Files picker.
  public func stage(documentAt url: URL) throws -> StagedFile {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    let name = url.lastPathComponent.isEmpty ? "attachment" : url.lastPathComponent
    let target = directory("staging").appendingPathComponent("\(UUID().uuidString)_\(safe(name))")
    try FileManager.default.copyItem(at: url, to: target)
    let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    return StagedFile(url: target, name: name, mimeType: mime, size: Self.size(of: target))
  }

  /// Stages bytes the app produced itself: a camera shot or a photo from the library, already converted to JPEG.
  public func stage(data: Data, name: String, mimeType: String) throws -> StagedFile {
    let target = directory("staging").appendingPathComponent("\(UUID().uuidString)_\(safe(name))")
    try data.write(to: target, options: .atomic)
    return StagedFile(url: target, name: name, mimeType: mimeType, size: data.count)
  }

  public func discard(_ staged: StagedFile) { try? FileManager.default.removeItem(at: staged.url) }

  /// One folder per attachment, so the file keeps its own name: that is what the preview and the share sheet show.
  func downloadTarget(attachmentId: Int, name: String) -> URL {
    directory("attachments/\(attachmentId)").appendingPathComponent(safe(name).isEmpty ? "attachment" : safe(name))
  }

  static func size(of url: URL) -> Int { (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
}
