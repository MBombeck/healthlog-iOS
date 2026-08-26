import Foundation

/// **M2 (AUDIT-PARITY-v11612) — per-account medications-list presentation.**
///
/// Wire shape of `GET/PUT /api/medications/layout` (server
/// `src/lib/medication-list-layout.ts`): a user-defined manual medication
/// order plus, historically, a chosen presentation. Per-account, persisted
/// server-side, preserve-when-absent on PUT.
///
/// **08-05 — cards are the only presentation this app has, and the type says
/// so.** The enum carries exactly one case, so no other presentation is
/// representable anywhere in the app rather than merely unreachable.
///
/// A payload written by the web, or by an older build of this app, may still
/// carry any string under `view`. Every one of them decodes to ``cards`` and
/// none of them is ever encoded back (see ``MedicationListLayout/encode(to:)``),
/// so a legacy value is **accepted and neutralised** — never restored as a
/// presentation and never rewritten as if the user had chosen it.
///
/// **Tolerant decode (mirrors the server resolver):** a malformed / partial /
/// legacy blob collapses onto the defaults field-by-field — a missing or
/// unrecognised `view` falls back to ``cards``, a missing `order` to `[]`. So a
/// GET can never fail and a future field defaults cleanly.
public enum MedicationListView: String, Codable, Sendable, CaseIterable {
    case cards

    /// Tolerant decode: every stored literal — current, legacy or future —
    /// degrades to ``cards`` rather than failing the whole layout decode.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = MedicationListView(rawValue: raw) ?? .cards
    }
}

public struct MedicationListLayout: Codable, Sendable, Equatable {
    /// Schema version — the server pins `1`. Decoded tolerantly (defaults to 1).
    public let version: Int
    /// Which presentation the list renders in — always
    /// ``MedicationListView/cards``, because that is the only case there is.
    ///
    /// **Decode-only — deliberately NOT re-encoded** (see ``encode(to:)``), so
    /// reading a legacy payload never turns into writing one back.
    public let view: MedicationListView
    /// User-defined manual medication order (medication ids, first = top).
    /// ids absent from the list are appended after the ordered block, ids that
    /// no longer resolve are ignored at apply time.
    public let order: [String]
    /// **CU-20 (#69) — optimistic-concurrency token.** Echoed as
    /// `baseUpdatedAt` on the next PUT; a stale one yields
    /// `409 medication_layout_conflict` and nothing is written. Guards the
    /// shared `User.updatedAt` (`api/medications/layout/route.ts:171`).
    ///
    /// **Decode-only — deliberately NOT re-encoded** (see ``encode(to:)``).
    /// `nil` on an older server, or after a DELETE reset (whose response
    /// carries no token, `route.ts:196-209`) — the next write is then
    /// unconditional, which the server supports permanently.
    public let updatedAt: String?

    /// Server-side upper bound on the persisted order list (200 entries).
    public static let orderMaxEntries = 200

    public static let `default` = MedicationListLayout(version: 1, view: .cards, order: [])

    public init(
        version: Int = 1,
        view: MedicationListView = .cards,
        order: [String] = [],
        updatedAt: String? = nil
    ) {
        self.version = version
        self.view = view
        self.order = order
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case version, view, order, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? container.decode(Int.self, forKey: .version)) ?? 1
        view = (try? container.decode(MedicationListView.self, forKey: .view)) ?? .cards
        order = (try? container.decode([String].self, forKey: .order)) ?? []
        // CU-20 — absent on an older server / after a DELETE reset.
        updatedAt = try? container.decodeIfPresent(String.self, forKey: .updatedAt)
    }

    /// Explicit (previously synthesized) so two fields stay **read-only**:
    ///
    /// - the CU-20 `updatedAt` token, which rides the write as `baseUpdatedAt`
    ///   via ``OptimisticWriteBody``, never under its own key;
    /// - `view` (08-05), because the app has one presentation and therefore no
    ///   presentation to state. Emitting it would turn a legacy value that was
    ///   merely *read* into one this app *wrote*, which is exactly what the
    ///   cards-only decision forbids. A decode of the omitted field lands on
    ///   ``MedicationListView/cards`` anyway, so the round trip is lossless.
    ///
    /// The write body proper is ``MedicationListLayoutPatch``.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(order, forKey: .order)
    }

    /// Reorders `medications` by the saved manual `order`: ids in `order`
    /// (that still resolve to a medication) come first in the saved sequence,
    /// then everything else keeps its incoming (server) order. A `nil` /
    /// empty order leaves the list untouched — pure passthrough.
    public func applied<M>(to medications: [M], id: (M) -> String) -> [M] {
        guard !order.isEmpty else { return medications }
        let rank = Dictionary(
            order.enumerated().map { ($0.element, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
        // Stable partition: ordered ids first (by saved rank), unranked ids
        // after in their original relative order.
        return medications.enumerated().sorted { lhs, rhs in
            let lhsRank = rank[id(lhs.element)]
            let rhsRank = rank[id(rhs.element)]
            switch (lhsRank, rhsRank) {
            case let (l?, r?): return l < r
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }
}

/// Wire body for `PUT /api/medications/layout`. `order` is optional so a client
/// can PUT exactly the field it changed (preserve-when-absent — an order-only
/// PUT keeps whatever presentation the server has stored, which is how a legacy
/// value survives untouched instead of being overwritten). `version` is always
/// sent (the server schema requires the literal `1`).
///
/// **08-13 — the presentation field is gone.** 08-05 reduced it to a constant
/// that only the inert `setListView` could pass; with that setter deleted the
/// field had no construction site left, and keeping an encodable presentation
/// on the write body is precisely the thing the cards-only decision forbids.
/// The app now has no way at all to state a presentation to the server.
public struct MedicationListLayoutPatch: Encodable, Sendable, Equatable {
    public let version: Int
    public let order: [String]?

    public init(order: [String]? = nil) {
        version = 1
        self.order = order
    }
}
