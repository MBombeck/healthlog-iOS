import Foundation

/// #141 (server v1.43) — one record related to the one shown, resolved on
/// the server (`RelatedLink` in the OpenAPI). The server lists only kinds whose
/// module is on and that the caller's sharing grant covers; the app renders
/// what it gets and never infers a relation itself.
public struct RelatedLink: Codable, Sendable, Hashable, Identifiable {
    /// The kinds the contract names. A kind the app does not know is skipped
    /// while decoding (see ``RelatedLinks``), never shown as a dead row.
    public enum Kind: String, Codable, Sendable, Hashable {
        case labResult, encounter, document, conditionEpisode, medication, vaccination

        /// Kinds with a page of their own in the app. A visit and a vaccination
        /// have none, so their rows stand without a chevron.
        public var opensInApp: Bool {
            switch self {
            case .labResult, .document, .conditionEpisode, .medication: true
            case .encounter, .vaccination: false
            }
        }

        /// SF Symbol for the row, the same glyphs the kinds use elsewhere.
        public var icon: String {
            switch self {
            case .labResult: "testtube.2"
            case .encounter: "stethoscope"
            case .document: "doc.text"
            case .conditionEpisode: "bandage"
            case .medication: "pills"
            case .vaccination: "syringe"
            }
        }
    }

    public let kind: Kind
    /// The related record's own id (the lab result, document, episode, …).
    public let recordID: String
    public let label: String
    /// `YYYY-MM-DD` or an ISO instant, as the record carries it.
    public let date: String?

    public var id: String {
        "\(kind.rawValue):\(recordID)"
    }

    public init(kind: Kind, recordID: String, label: String, date: String?) {
        self.kind = kind
        self.recordID = recordID
        self.label = label
        self.date = date
    }

    private enum CodingKeys: String, CodingKey {
        case kind, recordID = "id", label, date
    }
}

/// #141 — the `related` array, decoded leniently: an element with an
/// unknown `kind` or a missing required field is dropped, the rest stay. A value
/// that is not an array at all reads as empty, so `related` can never fail the
/// record it hangs on (a medication, a lab result, a document, an episode).
public struct RelatedLinks: Codable, Sendable, Hashable {
    public let items: [RelatedLink]

    public init(_ items: [RelatedLink]) {
        self.items = items
    }

    /// POLISH-A A2 — the document page lists its linked episodes once. The
    /// server stores the document-episode link and returns it both in
    /// `conditionLinks` (the editable "linked conditions" card) and in
    /// `related` (v1.47.0, `document:conditionEpisode` is a stored cell). The
    /// card is the live copy (an edit there updates it at once, `related`
    /// only on the next read), so `related` drops the episodes it already shows.
    public static func excludingEpisodes(_ links: [RelatedLink], linkedOn episodeIDs: Set<String>) -> [RelatedLink] {
        links.filter { !($0.kind == .conditionEpisode && episodeIDs.contains($0.recordID)) }
    }

    public init(from decoder: Decoder) throws {
        guard var container = try? decoder.unkeyedContainer() else {
            items = []
            return
        }
        var kept: [RelatedLink] = []
        while !container.isAtEnd {
            // `Lossy` always decodes, so the cursor moves on even when the
            // element itself is unreadable.
            guard let element = try? container.decode(Lossy.self) else { break }
            if let link = element.link, !link.recordID.isEmpty { kept.append(link) }
        }
        items = kept
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(items)
    }

    private struct Lossy: Decodable {
        let link: RelatedLink?

        init(from decoder: Decoder) throws {
            link = try? RelatedLink(from: decoder)
        }
    }
}
