import Foundation

/// The Insights **Recovery** family model — strain, training-load
/// (`CARDIO_LOAD`), autonomic-charge (`ANS_CHARGE`) and the daily
/// heart-and-energy items.
///
/// **v0141 W-DATAPARITY (P1) — built, not fetched.**
/// `RecoveryInsightsRepository` now BUILDS this value from the shared
/// `GET /api/analytics?slice=summaries` slice (the phantom
/// `GET /api/insights/recovery` route never existed). The tolerant
/// `init(from:)` below is retained because the BUILT family round-trips the
/// SWR disk cache (canonical `items` array form), and it stays permissive so a
/// future server-side recovery envelope could still decode directly.
///
/// **Server-authoritative, never recomputed.** The whole recovery family
/// (strain, training-load / `CARDIO_LOAD`, autonomic-charge / `ANS_CHARGE`,
/// and the daily heart-and-energy items) is computed server-side. iOS DECODES
/// and DISPLAYS the values verbatim — it never derives strain/load on-device.
/// HONEST-ONLY: only the items the server returns are rendered; an absent /
/// insufficient family is an honest empty state, never a fabricated value.
///
/// **Tolerant decode (forward/backward-compatible).** The endpoint is new and
/// its exact field layout may still settle, so this DTO is intentionally
/// permissive:
/// - every field is optional, decoded with `decodeIfPresent`;
/// - the family of recovery readings is a flat `[Item]` list keyed by an
///   `id` string, so the server can add / rename items without breaking decode;
/// - an item the client cannot place is still decoded (its `id` + `value`
///   carry through) rather than failing the whole payload;
/// - a `404` (route not deployed on an older server) / `422` maps to `nil` at
///   the repository, so an out-of-date server simply yields no recovery page.
///
/// **Assumption (flagged for server confirm, GH #23).** The contract describes
/// the payload in prose only. This DTO assumes the response is
/// `{ status, asOf?, items: [{ id, label?, value?, unit?, band?, score?,
/// trendDelta?, reason? }], note? }`. If the server ships a different envelope
/// (e.g. a keyed object rather than an array, or nests the family under a
/// `recovery`/`family` wrapper), the `init(from:)` below tolerates the common
/// shapes (array OR object-of-items) but the field names should be reconciled
/// against the server contract before the page is considered locked.
public struct RecoveryInsightsDTO: Codable, Sendable, Equatable {
    /// `"ok"` → at least one family item carries a value. `"insufficient"` (or
    /// anything non-`ok`) → the page renders its honest gating state. Defaults
    /// to `"insufficient"` when the server omits it (so an empty body never
    /// reads as a populated page).
    public let status: String
    /// Server compute time for the "as of" caption. `nil` ⇒ no chip.
    public let asOf: Date?
    /// The recovery family readings, in the server's display order. May be
    /// empty (the page then shows the empty/insufficient state).
    public let items: [Item]
    /// Optional short machine reason on the gated arm (localised client-side).
    public let reason: String?

    public init(status: String, asOf: Date? = nil, items: [Item] = [], reason: String? = nil) {
        self.status = status
        self.asOf = asOf
        self.items = items
        self.reason = reason
    }

    /// `true` when the family has at least one renderable value. Drives the
    /// page's data-gate: anything else is the honest empty state.
    public var hasContent: Bool {
        status == "ok" && items.contains { $0.hasValue }
    }

    // MARK: - Codable (tolerant — array OR object-of-items, wrapper-aware)

    /// Canonical keys — synthesizes `Encodable` (the SWR cache round-trips the
    /// decoded value back to disk, so the type must encode). iOS only ever
    /// re-encodes a value it decoded, so the canonical names suffice.
    private enum CodingKeys: String, CodingKey {
        case status, asOf, items, reason
    }

    /// Read-only probe keys for the tolerant decode (alternate spellings the
    /// server might use). NOT part of `CodingKeys`, so they never participate in
    /// `Encodable` synthesis.
    private enum ProbeKeys: String, CodingKey {
        case asOf, items, reason, family, recovery, metrics, computedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let p = try decoder.container(keyedBy: ProbeKeys.self)
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "insufficient"
        // Accept either `asOf` or `computedAt` for the timestamp.
        asOf = try c.decodeIfPresent(Date.self, forKey: .asOf)
            ?? p.decodeIfPresent(Date.self, forKey: .computedAt)
        reason = try c.decodeIfPresent(String.self, forKey: .reason)

        // The family may arrive under any of these keys, as an array OR a
        // `{ id: {…} }` object. Decode whichever is present, tolerantly.
        let keys: [ProbeKeys] = [.items, .family, .recovery, .metrics]
        var decoded: [Item] = []
        for key in keys where decoded.isEmpty {
            decoded = Self.decodeItems(from: p, forKey: key)
        }
        items = decoded
    }

    /// Decodes the family at `key` as an array of ``Item`` OR an object keyed by
    /// item id (`{ "STRAIN": {…} }` → the key becomes the item's `id` when the
    /// nested value omits one). A malformed element is skipped, never fatal.
    private static func decodeItems(
        from container: KeyedDecodingContainer<ProbeKeys>,
        forKey key: ProbeKeys
    ) -> [Item] {
        // Array form: `[ {id,…}, … ]`.
        if let array = try? container.decode([Item].self, forKey: key) {
            return array
        }
        // Object form: `{ "STRAIN": {…}, … }`. Use the outer key as a fallback id.
        if let map = try? container.decode([String: Item].self, forKey: key) {
            return map
                .map { outerKey, item in item.id.isEmpty ? item.withID(outerKey) : item }
                .sorted { $0.id < $1.id }
        }
        return []
    }

    // MARK: - Item (one recovery-family reading)

    /// One reading in the recovery family — strain, training-load
    /// (`CARDIO_LOAD`), autonomic-charge (`ANS_CHARGE`), or a daily
    /// heart-and-energy item. The server may emit a 0–100 `score` (rendered as
    /// a ring) OR a raw `value` + `unit` (rendered as a stat card); both are
    /// optional so one struct covers every archetype. Nothing is fabricated:
    /// an item with neither a `score` nor a `value` is non-renderable
    /// (``hasValue`` is false) and the page omits it.
    public struct Item: Codable, Sendable, Equatable, Identifiable {
        /// Stable server id (e.g. `STRAIN`, `CARDIO_LOAD`, `ANS_CHARGE`,
        /// `HEART_RATE`, `ACTIVE_ENERGY`). Used as the SwiftUI identity + to
        /// pick the localized label when the server omits one.
        public let id: String
        /// Server-provided display label. `nil` ⇒ resolve a localized label
        /// from ``id`` client-side.
        public let label: String?
        /// Raw numeric value for the stat archetype (e.g. training-load points,
        /// kJ, bpm). `nil` for the pure-score archetype.
        public let value: Double?
        /// Unit string the server emits for `value` (e.g. `"kJ"`, `"bpm"`).
        /// Rendered as-is, never reinterpreted. `nil` ⇒ bare number.
        public let unit: String?
        /// 0–100 composite score for the ring archetype (strain / charge).
        /// `nil` ⇒ this item renders as a stat, not a ring.
        public let score: Double?
        /// Server band string (`green/yellow/red`, or a charge band). Drives the
        /// single signal dot; rendered as-is. `nil` ⇒ pure-mono.
        public let band: String?
        /// Change vs the trailing baseline the server computed. `nil` ⇒ no trend
        /// line (never fabricated).
        public let trendDelta: Double?
        /// Per-item gating reason when this single reading is insufficient.
        public let reason: String?

        public init(
            id: String,
            label: String? = nil,
            value: Double? = nil,
            unit: String? = nil,
            score: Double? = nil,
            band: String? = nil,
            trendDelta: Double? = nil,
            reason: String? = nil
        ) {
            self.id = id
            self.label = label
            self.value = value
            self.unit = unit
            self.score = score
            self.band = band
            self.trendDelta = trendDelta
            self.reason = reason
        }

        /// Canonical keys — synthesize `Encodable` for the SWR round-trip.
        private enum CodingKeys: String, CodingKey {
            case id, label, value, unit, score, band, trendDelta, reason
        }

        /// Read-only probe keys (alternate spellings); excluded from `Encodable`.
        private enum ProbeKeys: String, CodingKey {
            case id, label, key, name, title
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let p = try decoder.container(keyedBy: ProbeKeys.self)
            id = try c.decodeIfPresent(String.self, forKey: .id)
                ?? p.decodeIfPresent(String.self, forKey: .key)
                ?? ""
            label = try c.decodeIfPresent(String.self, forKey: .label)
                ?? p.decodeIfPresent(String.self, forKey: .name)
                ?? p.decodeIfPresent(String.self, forKey: .title)
            value = try c.decodeIfPresent(Double.self, forKey: .value)
            unit = try c.decodeIfPresent(String.self, forKey: .unit)
            score = try c.decodeIfPresent(Double.self, forKey: .score)
            band = try c.decodeIfPresent(String.self, forKey: .band)
            trendDelta = try c.decodeIfPresent(Double.self, forKey: .trendDelta)
            reason = try c.decodeIfPresent(String.self, forKey: .reason)
        }

        /// `true` when the item carries a renderable value (a score OR a raw
        /// value). HONEST-ONLY: an item with neither is never painted.
        public var hasValue: Bool {
            score != nil || value != nil
        }

        /// `true` when this item is a 0–100 composite (render as a ring); else a
        /// raw stat (render as a number + unit).
        public var isScore: Bool {
            score != nil
        }

        /// Returns a copy with `id` replaced — used when the family arrives as a
        /// `{ id: {…} }` object and the nested value omitted its own id.
        func withID(_ newID: String) -> Item {
            Item(
                id: newID,
                label: label,
                value: value,
                unit: unit,
                score: score,
                band: band,
                trendDelta: trendDelta,
                reason: reason
            )
        }
    }
}
