import Foundation

/// Someone a letter's content key is sealed to. `keyVersion` is required for groups (their keys rotate).
public struct Reader: Equatable, Sendable {
  public static let user = "user"
  public static let chapter = "chapter"

  public let type: String
  public let id: Int
  public let publicKey: String
  public let keyVersion: Int?

  public init(type: String, id: Int, publicKey: String, keyVersion: Int? = nil) {
    self.type = type
    self.id = id
    self.publicKey = publicKey
    self.keyVersion = keyVersion
  }
}

public struct Envelope: Equatable, Sendable {
  public let readerType: String
  public let readerId: Int
  public let wrappedKey: String
  public let keyVersion: Int?
}

public struct EncryptedText: Equatable, Sendable {
  public let ciphertext: String
  public let nonce: String
}

public struct EncryptedLetter: Sendable {
  public let body: EncryptedText
  public let relayNote: EncryptedText?
  public let envelopes: [Envelope]
  /// Kept by the caller only long enough to encrypt attachments under the same key.
  public let contentKey: Data
}

public struct CannotOpenError: Error, Equatable {
  public let message: String
}

/// One random content key per letter; the body, the relay note, and every
/// attachment are encrypted with it (fresh nonce each), and the key itself is
/// sealed once per reader. Adding a reader later never touches the letter.
public enum LetterCipher {

  public static func encrypt(body: String, relayNote: String?, readers: [Reader]) throws -> EncryptedLetter {
    precondition(!readers.isEmpty, "a letter needs at least one reader")
    let contentKey = Sodium.randomBytes(Sodium.keyBytes)
    let note = relayNote.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
    return EncryptedLetter(
      body: try encryptText(body, contentKey: contentKey),
      relayNote: try note.map { try encryptText($0, contentKey: contentKey) },
      envelopes: try readers.map { try seal(contentKey: contentKey, to: $0) },
      contentKey: contentKey
    )
  }

  public static func seal(contentKey: Data, to reader: Reader) throws -> Envelope {
    Envelope(
      readerType: reader.type,
      readerId: reader.id,
      wrappedKey: Sodium.toBase64(try Sodium.seal(contentKey, to: try Sodium.fromBase64(reader.publicKey))),
      keyVersion: reader.keyVersion
    )
  }

  /// Throws `CannotOpenError` when the envelope was not sealed to this keypair.
  public static func openEnvelope(_ wrappedKey: String, keyPair: Sodium.KeyPair) throws -> Data {
    do {
      return try Sodium.sealOpen(try Sodium.fromBase64(wrappedKey), publicKey: keyPair.publicKey, privateKey: keyPair.privateKey)
    } catch {
      throw CannotOpenError(message: "This letter was not sealed to your key.")
    }
  }

  public static func encryptText(_ text: String, contentKey: Data) throws -> EncryptedText {
    let enc = try Sodium.aeadEncrypt(Data(text.utf8), key: contentKey)
    return EncryptedText(ciphertext: Sodium.toBase64(enc.ciphertext), nonce: Sodium.toBase64(enc.nonce))
  }

  public static func decryptText(ciphertext: String, nonce: String, contentKey: Data) throws -> String {
    do {
      let plain = try Sodium.aeadDecrypt(try Sodium.fromBase64(ciphertext), nonce: try Sodium.fromBase64(nonce), key: contentKey)
      return String(decoding: plain, as: UTF8.self)
    } catch {
      throw CannotOpenError(message: "This letter could not be decrypted.")
    }
  }

  /// Attachment bytes under the letter's content key; the nonce travels as a form field.
  public static func encryptFile(_ bytes: Data, contentKey: Data) throws -> (ciphertext: Data, nonce: String) {
    let enc = try Sodium.aeadEncrypt(bytes, key: contentKey)
    return (enc.ciphertext, Sodium.toBase64(enc.nonce))
  }

  public static func decryptFile(_ ciphertext: Data, nonce: String, contentKey: Data) throws -> Data {
    do {
      return try Sodium.aeadDecrypt(ciphertext, nonce: try Sodium.fromBase64(nonce), key: contentKey)
    } catch {
      throw CannotOpenError(message: "This file could not be decrypted.")
    }
  }
}
