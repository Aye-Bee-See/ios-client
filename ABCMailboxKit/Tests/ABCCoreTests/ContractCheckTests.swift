@testable import ABCCore
import XCTest

/// Checks the app against a running API, not against our idea of it. The captures are made by the
/// Android tools, so both clients are held to the same responses:
///
///     python3 ../Android/tools/capture-contract.py /tmp/contract
///     ABC_CONTRACT_DIR=/tmp/contract swift test --filter ContractCheck
///
/// Skipped unless ABC_CONTRACT_DIR is set, so ordinary test runs need no server. Every captured
/// response is decoded with the type the app really uses for it, which catches a changed type or a
/// field that became required. (Android's version also lists declared fields that no response
/// contains; Swift's `Decodable` cannot enumerate a type's fields, so that half lives there only.)
final class ContractCheckTests: XCTestCase {

  private func enveloped<T: Decodable>(_: T.Type) -> (Data) throws -> Void { { _ = try JSONDecoder().decode(APIEnvelope<T>.self, from: $0) } }

  /// Capture name (without the mode prefix) to the type the app decodes that response into.
  private var contracts: [String: (Data) throws -> Void] {
    [
      "health": { _ = try JSONDecoder().decode(HealthDTO.self, from: $0) },
      "login.user1": enveloped(LoginData.self), "login.member1": enveloped(LoginData.self),
      "keys.writer": enveloped(KeyBundleDTO.self), "keys.member": enveloped(KeyBundleDTO.self),
      "publicKey.user": enveloped(PublicKeyDTO.self), "publicKey.chapter": enveloped(PublicKeyDTO.self),
      "recoverStart": enveloped(RecoverStartDTO.self), "claimInfo": enveloped(ClaimInfoDTO.self),
      "prisoners": enveloped([PrisonerDTO].self), "prisoners.featured": enveloped([PrisonerDTO].self), "prisoner": enveloped(PrisonerDTO.self),
      "prisons": enveloped([PrisonDTO].self), "prison": enveloped(PrisonDTO.self), "mailRules": enveloped(MailRuleVocabularyDTO.self),
      "chapters": enveloped([ChapterDTO].self), "chapter": enveloped(ChapterDTO.self),
      "chats": enveloped([ChatDTO].self), "chats.member": enveloped([ChatDTO].self), "chat": enveloped(ChatDTO.self), "chatByPrisoner": enveloped(ChatDTO.self),
      "message": enveloped(MessageDTO.self), "queue": enveloped([MessageDTO].self), "attachments": enveloped([AttachmentDTO].self),
      "retention": enveloped(RetentionDTO.self),
      "writers": enveloped([WriterDTO].self), "issueToken": enveloped(IssuedTokenDTO.self), "memberKeys": enveloped(MemberKeysDTO.self),
      // The app reads `GET /auth/user` nowhere; Android captures it, so it is checked for completeness.
      "user": enveloped(UserDTO.self),
    ]
  }

  func testEveryCapturedResponseDecodesWithTheTypeTheAppUsesForIt() throws {
    guard let path = ProcessInfo.processInfo.environment["ABC_CONTRACT_DIR"] else {
      throw XCTSkip("set ABC_CONTRACT_DIR to a directory made by Android/tools/capture-contract.py")
    }
    let files = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: path), includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }
    guard !files.isEmpty else { throw XCTSkip("no captures in \(path)") }
    var failures: [String] = [], unmapped: [String] = []
    for file in files {
      // "server.prisoners.featured.json" -> "prisoners.featured"
      let name = file.deletingPathExtension().lastPathComponent.split(separator: ".").dropFirst().joined(separator: ".")
      guard let decode = contracts[name] else { unmapped.append(file.lastPathComponent); continue }
      do { try decode(Data(contentsOf: file)) } catch { failures.append("\(file.lastPathComponent): \(error)") }
    }
    print("Contract check: \(files.count) captured responses, \(failures.count) failures." + (unmapped.isEmpty ? "" : " No contract registered for: \(unmapped)"))
    XCTAssertEqual(failures, [], "responses the app's types can no longer read")
  }
}
