import Foundation

/// `address` and `location` are free-form JSON objects. The seeds use
/// `{"street": ...}`; real records may add city, region, postcode. Known keys
/// come out in postal order, unknown ones after (alphabetically, since a Swift
/// dictionary forgets the order they arrived in), empty values dropped.
func addressLines(_ object: [String: JSONValue]?) -> [String] {
  guard let object else { return [] }
  let order = ["name", "line1", "line2", "street", "city", "region", "state", "postcode", "zip", "country"]
  let known = order.compactMap { object[$0]?.text }
  let rest = object.keys.filter { !order.contains($0) }.sorted().compactMap { object[$0]?.text }
  return (known + rest).filter { !$0.isBlank }
}

extension PrisonDTO {
  /// `catalog` supplies labels for the rule tags; the default is the compiled-in vocabulary.
  func toDomain(_ catalog: MailRuleCatalog = .compiled) -> Facility {
    Facility(
      id: id,
      name: prisonName,
      addressLines: addressLines(address),
      country: country,
      routing: .from(key: routing),
      scanService: scanService?.nonBlank,
      notes: notes?.nonBlank,
      verification: Verification(byGroupId: verifiedBy, at: verifiedAt.instant),
      prisoners: (prisoners ?? []).map { $0.toDomain(catalog) },
      rules: MailRules(
        rules: catalog.resolveAll(
          mailRules ?? [],
          // A detail with no label of its own falls back to what the catalog knows for that tag.
          details: (mailRuleDetails ?? []).map { MailRule($0.tag, $0.category ?? "other", $0.label?.nonBlank ?? catalog.resolve($0.tag).label, $0.description) }
        ),
        pageLimit: pageLimit.flatMap { $0 > 0 ? $0 : nil },
        photoLimit: photoLimit.flatMap { $0 > 0 ? $0 : nil },
        languages: (mailLanguages ?? []).map { $0.lowercased() }
      ),
      relayGroups: (relayGroups ?? []).map { $0.toDomain(catalog) }
    )
  }
}

extension PrisonerDTO {
  func toDomain(_ catalog: MailRuleCatalog = .compiled) -> Prisoner {
    let chosen = chosenName?.nonBlank, birth = birthName?.nonBlank
    return Prisoner(
      id: id,
      name: chosen ?? birth ?? "Unnamed",
      birthName: birth == chosenName ? nil : birth,
      aliases: (aliases ?? []).filter { !$0.isBlank },
      facilityId: prison,
      facility: prisonDetails?.toDomain(catalog),
      country: country ?? prisonDetails?.country,
      detainedSince: detainedSince.utcDay,
      releaseDate: releaseDate.utcDay,
      sentence: sentence?.nonBlank,
      charges: charges?.nonBlank,
      estimatedRelease: estimatedRelease?.nonBlank,
      bio: bio?.nonBlank,
      interests: (interests ?? []).filter { !$0.isBlank },
      photoUrl: photoUrl?.nonBlank,
      supportWebsite: supportWebsite?.nonBlank,
      donationInfo: donationInfo?.nonBlank,
      status: status,
      statusNotice: statusNotice?.nonBlank,
      featured: featured ?? false,
      verification: Verification(byGroupId: verifiedBy, at: verifiedAt.instant),
      supportGroups: (supportGroups ?? []).map { $0.toDomain(catalog) },
      inmateId: inmateID?.nonBlank
    )
  }
}

extension ChapterDTO {
  func toDomain(_ catalog: MailRuleCatalog = .compiled) -> SupportGroup {
    SupportGroup(
      id: id,
      name: name,
      subregion: subregion?.nonBlank ?? addressLines(location).first,
      country: country?.nonBlank,
      about: about?.nonBlank,
      website: website?.nonBlank,
      email: email?.nonBlank,
      socialLinks: (socialLinks ?? [:]).compactMapValues { $0?.nonBlank },
      services: services ?? [],
      announcement: announcement?.nonBlank,
      networkRole: networkRole,
      accountStatus: accountStatus,
      supportedPrisoners: (supportedPrisoners ?? []).map { $0.toDomain(catalog) },
      relayPrisons: (relayPrisons ?? []).map { $0.toDomain(catalog) },
      supportDescription: prisonerSupport?.description?.nonBlank
    )
  }
}

extension AttachmentDTO {
  func toDomain() -> Attachment { Attachment(id: id, messageId: message, name: originalName, mimeType: mimeType, size: size, nonce: nonce) }
}

extension MessageDTO {
  /// In end-to-end mode `messageText` is null and the body arrives as ciphertext; `LetterCodec.incoming` fills it in.
  func toDomain() -> Letter {
    Letter(
      id: id,
      threadId: chat,
      prisonerId: prisoner,
      writerId: user,
      fromPrisoner: sender == "prisoner",
      status: .from(key: status),
      body: messageText ?? "",
      relayNote: relayNote?.nonBlank,
      relayGroupId: relayChapter ?? relayGroup?.id,
      relayGroupName: relayGroup?.name,
      keep: keep ?? false,
      createdAt: createdAt.instant,
      statusChangedAt: statusChangedAt.instant,
      history: (statusHistory ?? []).map { StatusChange(from: $0.fromStatus.map { LetterStatus.from(key: $0) }, to: .from(key: $0.toStatus), at: $0.createdAt.instant, byUserId: $0.changedBy) },
      attachments: (attachments ?? []).map { $0.toDomain() }
    )
  }
}

extension ChatDTO {
  /// `letter` and `preview` let the caller decrypt in end-to-end mode; the defaults are the server-mode pass-through.
  func toDomain(
    letter: (MessageDTO) -> Letter = { $0.toDomain() },
    preview: (LastMessageDTO) -> String? = { $0.messageText?.nonBlank }
  ) -> LetterThread {
    LetterThread(
      id: id,
      prisonerId: prisoner,
      prisoner: prisonerDetails?.toDomain(),
      lastMessage: lastMessage.map { LastMessage(id: $0.id, fromPrisoner: $0.sender == "prisoner", status: .from(key: $0.status), at: $0.createdAt.instant, preview: preview($0)) },
      lastActivity: lastMessageAt.instant ?? updatedAt.instant,
      // Oldest first for a conversation view; the API returns them in insertion order already.
      letters: (messages ?? []).map(letter).enumerated()
        .sorted { a, b in (a.element.createdAt ?? .distantPast, a.offset) < (b.element.createdAt ?? .distantPast, b.offset) }
        .map(\.element),
      writer: userDetails.map { ThreadWriter(id: $0.id, name: $0.name?.nonBlank ?? $0.username, managedByGroupId: $0.managedBy, anonymousForGroupId: $0.anonymousForChapter) }
    )
  }
}

extension WriterDTO {
  func toDomain() -> ManagedWriter {
    ManagedWriter(
      id: id,
      name: name?.nonBlank ?? username ?? "Writer \(id)",
      email: email?.nonBlank.flatMap { $0.hasSuffix("@managed.example") ? nil : $0 },
      note: managerNote?.nonBlank,
      tokenExpiresAt: claimToken?.expiresAt.instant
    )
  }
}
