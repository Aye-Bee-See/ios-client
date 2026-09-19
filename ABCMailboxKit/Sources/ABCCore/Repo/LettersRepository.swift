import Foundation

@MainActor
public final class LettersRepository {
  private let api: APIClient
  private let files: LocalFiles
  private let codec: LetterCodec
  private let engine: CryptoEngine

  init(api: APIClient, files: LocalFiles, codec: LetterCodec, engine: CryptoEngine) {
    self.api = api
    self.files = files
    self.codec = codec
    self.engine = engine
  }

  private func decoded(_ chat: ChatDTO) -> LetterThread { chat.toDomain(letter: codec.incoming, preview: codec.preview) }

  /// Chats keep server order (newest activity first); the brief warns not to re-sort.
  public func threads(page: Int, pageSize: Int) async throws -> Page<LetterThread> {
    await codec.ready()
    let envelope: APIEnvelope<[ChatDTO]> = try await api.get("chat/chats", query: [("full", "true"), ("page", String(page)), ("page_size", String(pageSize))])
    return envelope.toPage().map(decoded)
  }

  public func thread(chatId: Int) async throws -> LetterThread {
    await codec.ready()
    let envelope: APIEnvelope<ChatDTO> = try await api.get("chat/chat", query: [("id", String(chatId)), ("full", "true")])
    return decoded(try envelope.required("conversation"))
  }

  func message(_ id: Int) async throws -> MessageDTO {
    let envelope: APIEnvelope<MessageDTO> = try await api.get("messaging/message", query: [("id", String(id)), ("full", "true")])
    return try envelope.required("letter")
  }

  public func letter(messageId: Int) async throws -> Letter {
    await codec.ready()
    return codec.incoming(try await message(messageId))
  }

  public func send(_ letter: NewLetter) async throws -> Letter {
    // A 409 here means a group rotated its key between our lookup and the send: encode again
    // (which fetches the new public key and version) and retry once.
    for attempt in 0..<2 {
      let request = try await codec.outgoing(letter).request
      do {
        let envelope: APIEnvelope<MessageDTO> = try await api.send("POST", "messaging/message", body: request)
        return codec.incoming(try envelope.required("sent letter"))
      } catch let e as AppError where e.isConflict && attempt == 0 {
        await codec.refreshKeys()
      }
    }
    throw AppError.unexpected("unreachable")
  }

  public func edit(_ edit: LetterEdit) async throws {
    await codec.ready()
    let request = try codec.edit(edit, existing: try await message(edit.messageId))
    try await api.send("PUT", "messaging/message", body: request)
  }

  public func delete(messageId: Int) async throws {
    try await api.send("DELETE", "messaging/message", body: IdBody(id: messageId))
  }

  public func upload(messageId: Int, staged: StagedFile) async throws -> Attachment {
    await codec.ready()
    let bytes: Data
    do { bytes = try Data(contentsOf: staged.url) } catch { throw AppError.unexpected("Could not read \(staged.name).") }
    var fields = [("message", String(messageId))]
    var payload = bytes
    if await codec.isEndToEnd() {
      // End-to-end: the file is encrypted under the letter's content key before it leaves the phone.
      // The declared type still describes the plaintext; the server does not sniff ciphertext.
      guard let key = codec.contentKey(try await message(messageId)) else { throw AppError.lettersLocked }
      let encrypted = try await LetterCodec.sealingAsync { try await self.engine.encryptFile(bytes, contentKey: key) }
      payload = encrypted.ciphertext
      fields.append(("nonce", encrypted.nonce))
    }
    let envelope: APIEnvelope<AttachmentDTO> = try await api.upload("messaging/attachment", fields: fields, file: UploadFile(field: "file", filename: staged.name, mimeType: staged.mimeType, data: payload))
    return try envelope.required("attachment").toDomain()
  }

  public func deleteAttachment(id: Int) async throws {
    try await api.send("DELETE", "messaging/attachment", body: IdBody(id: id))
  }

  /// Downloads to the cache and returns the file; a second call for the same attachment is instant.
  public func download(_ attachment: Attachment) async throws -> URL {
    await codec.ready()
    let target = files.downloadTarget(attachmentId: attachment.id, name: attachment.name)
    // In end-to-end mode the server only ever saw ciphertext, so the size it reports is 16 bytes
    // (the authentication tag) more than the file kept here. Either size counts as "already downloaded".
    let onDisk = LocalFiles.size(of: target)
    let sizes = attachment.nonce == nil ? [attachment.size] : [attachment.size, attachment.size - 16]
    if FileManager.default.fileExists(atPath: target.path), sizes.contains(onDisk) { return target }

    var bytes = try await api.download("messaging/attachment", query: [("id", String(attachment.id))])
    if let nonce = attachment.nonce {
      // End-to-end: what comes down is ciphertext; open it with the letter's content key.
      guard let key = codec.contentKey(try await message(attachment.messageId)) else { throw AppError.lettersLocked }
      let cipherBytes = bytes
      do { bytes = try await engine.decryptFile(cipherBytes, nonce: nonce, contentKey: key) } catch { throw AppError.forbidden("This file could not be decrypted.") }
    }
    do { try bytes.write(to: target, options: [.atomic, .completeFileProtection]) } catch { throw AppError.unexpected("Could not save \(attachment.name).") }
    return target
  }

  public func retentionDays() async throws -> Int? {
    let envelope: APIEnvelope<RetentionDTO> = try await api.get("messaging/retention")
    return envelope.data?.effectiveDays
  }
}

extension LetterCodec {
  nonisolated static func sealingAsync<T: Sendable>(_ work: @Sendable () async throws -> T) async throws -> T {
    do { return try await work() } catch let e as AppError { throw e } catch { throw AppError.unexpected("Encryption failed: \(error)") }
  }
}
