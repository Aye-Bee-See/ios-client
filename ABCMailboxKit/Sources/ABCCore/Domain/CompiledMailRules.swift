import Foundation

/// GENERATED from `GET /prison/mail-rules`; do not edit by hand. This is the same
/// vocabulary the Android client compiles in (Android `tools/gen-mail-rules.py`);
/// a test fails if it falls behind the server's.
///
/// The fallback vocabulary, so facility rules render before the live one has been
/// fetched and when the phone is offline. The live vocabulary wins when present, which
/// is how a tag added on the server gets a proper label without an app release.
enum CompiledMailRules {
  static let categories: [String] = ["addressing", "paper_and_ink", "content", "photos", "enclosures", "publications", "senders", "handling"]

  static let rules: [MailRule] = [
    MailRule("return_address_required", "addressing", "Return address required", "Every envelope needs a full sender name and postal address or it is refused."),
    MailRule("full_name_and_number", "addressing", "Full name and number", "Address mail with the prisoner's full legal name and inmate number; nicknames are not delivered."),
    MailRule("plain_envelopes", "addressing", "Plain envelopes only", "White or manila envelopes with no stickers, tape, drawings, or coloured ink."),
    MailRule("no_stickers_or_labels", "addressing", "No stickers or labels", "Address labels, stickers, and stamps other than postage are not allowed on the envelope."),
    MailRule("one_letter_per_envelope", "addressing", "One letter per envelope", "Envelopes containing letters for more than one prisoner are returned."),
    MailRule("registered_post_recommended", "addressing", "Registered post recommended", "Ordinary international post is often lost; send letters by registered or tracked mail."),
    MailRule("plain_paper", "paper_and_ink", "Plain paper only", "White lined or unlined paper; no cardstock, construction paper, or scented paper."),
    MailRule("ink_blue_or_black", "paper_and_ink", "Blue or black ink only", "Letters written in pencil, marker, crayon, or coloured ink are rejected."),
    MailRule("typed_letters_allowed", "paper_and_ink", "Typed letters allowed", "Typed and printed letters are accepted as long as the pages are unbound."),
    MailRule("handwritten_only", "paper_and_ink", "Handwritten letters only", "Typed or printed letters are refused; write by hand."),
    MailRule("postcards_only", "paper_and_ink", "Postcards only", "This facility accepts standard-size postcards only; enclosed letters are returned."),
    MailRule("no_greeting_cards", "paper_and_ink", "No greeting cards", "Cards with layers, glitter, pop-ups, or musical parts are refused; a flat card is accepted."),
    MailRule("no_scents_or_lipstick", "paper_and_ink", "No perfume or lipstick", "Scented, stained, or lipstick-marked paper is treated as contaminated and destroyed."),
    MailRule("no_glue_tape_or_staples", "paper_and_ink", "No glue, tape, or staples", "Nothing may be glued, taped, or stapled to the pages."),
    MailRule("no_maps", "content", "No maps", "Maps, including hand-drawn ones, are treated as escape material and confiscated."),
    MailRule("no_coded_messages", "content", "No coded messages", "Letters containing ciphers, symbols, or unexplained abbreviations are held for investigation."),
    MailRule("no_drawings_by_others", "content", "No drawings by others", "Hand-drawn artwork is accepted only from the sender; drawings by children or others are refused."),
    MailRule("no_third_party_mail", "content", "No third-party mail", "Mail that forwards or relays a message from someone else is refused."),
    MailRule("no_photos", "photos", "No pictures", "Letters must be text only; photographs and printed images are returned."),
    MailRule("no_polaroids", "photos", "No polaroids", "Instant-film photographs are refused because the backing can hide contraband."),
    MailRule("no_explicit_photos", "photos", "No nude or suggestive photos", "Photographs showing nudity, underwear, or sexually suggestive poses are destroyed."),
    MailRule("no_gang_imagery", "photos", "No gang signs in photos", "Photographs showing hand signs, gang colours, or gang tattoos are refused."),
    MailRule("no_enclosures", "enclosures", "Nothing enclosed", "Nothing may be enclosed with a letter: no stamps, cash, cards, or objects of any kind."),
    MailRule("no_stamps_enclosed", "enclosures", "Stamps not accepted", "Enclosed postage stamps are confiscated; stamps must be bought at the commissary."),
    MailRule("no_money", "enclosures", "No money orders", "Funds cannot be sent by mail; use the facility's deposit service."),
    MailRule("no_clippings", "enclosures", "No newspaper clippings", "Cuttings and printed articles are refused; write out or describe the content instead."),
    MailRule("printed_pages_allowed", "enclosures", "Printed internet pages allowed", "Printed web pages are accepted if they are plain black-and-white text with no images."),
    MailRule("books_from_publisher_only", "publications", "Books from publishers only", "Books must ship new from a publisher or approved bookseller, never from an individual."),
    MailRule("paperbacks_only", "publications", "Paperbacks only", "Hardcover books are refused; send paperback editions."),
    MailRule("approved_senders_only", "senders", "No unknown senders", "Only senders on the prisoner's approved correspondence list are delivered."),
    MailRule("sender_approval_form", "senders", "Sender approval form", "New correspondents must file the facility's approval form before their first letter is delivered."),
    MailRule("no_inter_prisoner_mail", "senders", "No mail between prisoners", "Correspondence with anyone held in another facility requires prior written approval."),
    MailRule("mail_read_by_staff", "handling", "Mail opened and read", "All incoming mail except legal mail is opened and read by staff before delivery."),
    MailRule("legal_mail_marked", "handling", "Legal mail marked clearly", "Mail from a lawyer must be marked Legal Mail with the firm's address or it is opened as ordinary mail."),
    MailRule("originals_destroyed", "handling", "Scanned, not delivered", "Incoming mail is scanned by a vendor and shown on a tablet; the paper original is destroyed."),
    MailRule("scanned_in_greyscale", "handling", "Scanned mail: no colour", "Because mail is scanned in greyscale, colour drawings and photos arrive as black and white."),
    MailRule("digital_mail_only", "handling", "Digital mail only", "Letters must be sent through the facility's electronic mail service; postal mail is returned."),
    MailRule("delivery_not_confirmed", "handling", "Delivery not confirmed", "The facility does not confirm delivery; expect delays of four to eight weeks."),
    MailRule("holiday_card_limit", "handling", "Holiday mail limits", "In December only, up to two cards per sender are accepted."),
  ]
}
