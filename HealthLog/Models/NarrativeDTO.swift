import Foundation

/// Wire-form mirror of `GET /api/insights/narrative?period=week|month`
/// (server v1.11.0 W3, route at `src/app/api/insights/narrative/route.ts`).
///
/// **What it serves.** The "Zeitraum im Rückblick" / period-retrospective prose
/// — an LLM narration over a structured, citation-carrying context (per-metric
/// deltas vs the equal prior period, band transitions, FDR-surviving drivers,
/// coincident out-of-band days). The route is **read-only stale-while-revalidate
/// by construction** (the v1.8.3 freeze posture): it never blocks on the
/// provider and serves the last-good narrative immediately, warming the next
/// period out of band.
///
/// **Display-only on iOS (I-3 ITEM 5).** iOS mirrors the text 1:1 — never
/// paraphrases, never recomputes. A reusable EXPORT of the retrospective is a
/// separate SERVER coordination item (the narrative is absent from `/api/export`
/// + the doctor PDF today); this client surfaces the read route only.
///
/// **`narrative == nil` arms.** A fresh / provider-less account returns
/// `{ narrative: null, revalidating: … }` — the card renders a calm empty
/// state, never a spinner-forever. A `404` (route not deployed) / `422`
/// (unknown period rejected by the closed enum) maps to `nil` in the repo so
/// the card hides cleanly.
public struct NarrativeDTO: Codable, Sendable, Equatable {
    /// Echoed period (`week` | `month`).
    public let period: String
    /// Resolved locale (`de` | `en`) — server narrows from the session.
    public let locale: String?
    /// The last-good narrative, or `nil` when none has been generated yet.
    public let narrative: Narrative?
    /// `true` when the server enqueued an out-of-band warm because the row was
    /// stale / missing AND a provider is configured. Display hint only — the
    /// card never blocks on it.
    public let revalidating: Bool?

    public init(period: String, locale: String?, narrative: Narrative?, revalidating: Bool?) {
        self.period = period
        self.locale = locale
        self.narrative = narrative
        self.revalidating = revalidating
    }

    /// One generated period narrative.
    ///
    /// **`provenance` is deliberately NOT modelled (v0.14.7 A2).** The server's
    /// `provenance` field is a structured OBJECT (`{metrics, window, pairsTested,
    /// fdrQ, computedAt}`), not the `String` an earlier draft assumed — decoding
    /// it as `String?` threw `DecodingError` the moment a real narrative row
    /// existed (exactly when content should appear), which surfaced as the
    /// recurring "Der Rückblick konnte gerade nicht geladen werden" error. iOS
    /// never renders provenance, so the field is simply omitted: Codable ignores
    /// unknown keys, so this now tolerates ANY provenance shape (string, object,
    /// or future drift) without breaking the card. The repo also defends with a
    /// `catch HLError.decoding → nil` belt-and-braces.
    public struct Narrative: Codable, Sendable, Equatable {
        /// The prose, rendered VERBATIM (server-output contract — never
        /// paraphrase or summarise).
        public let text: String
        /// When the narrative was generated (ISO 8601).
        public let updatedAt: Date?

        public init(text: String, updatedAt: Date?) {
            self.text = text
            self.updatedAt = updatedAt
        }
    }

    /// The two periods the route accepts (closed enum mirrors the server's
    /// `PERIOD_DAYS` keys). The query value is the lowercase `rawValue`.
    public enum Period: String, CaseIterable, Sendable, Identifiable {
        case week
        case month

        public var id: String {
            rawValue
        }
    }
}
