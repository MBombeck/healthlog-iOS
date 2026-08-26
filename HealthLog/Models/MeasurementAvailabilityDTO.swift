import Foundation

// Availability slice (v0.13.1 IC).
//
// Reine Verschiebung aus `MeasurementDTO.swift` (CU-18): die Datei lief über
// das 1000-Zeilen-Budget, dieser Block ist der thematisch eigenständigste.
// Kein Verhaltens- oder Signatur-Unterschied.

/// Decoder for the slim summaries slice `GET /api/analytics?slice=summaries`
/// (server `computeSummariesSlice`, `src/lib/analytics/summaries-slice.ts`).
/// The slice carries a per-`MeasurementType` `DataSummary` map whose `count`
/// is the **all-time** observation count — the per-kind has-data signal the
/// web tab-strip gates its pills on (`metric-availability.ts:hasMetricData`).
///
/// We decode ONLY the `summaries` map's `count` field — the slice also carries
/// `bmi` / `latest` / windowed averages / slope tuples / `lastSeenByType`, but
/// availability needs nothing past the count, and modelling the rest would
/// over-couple this DTO. Keys are the server `MeasurementType` strings
/// (`WEIGHT`, `BLOOD_PRESSURE_SYS`, `ACTIVITY_STEPS`, …); `MetricKind.
/// availabilitySummaryKey` maps a kind onto its key.
///
/// **Not AI-gated:** the analytics route is deterministic metric math behind a
/// plain `requireAuth`, so the availability path never trips the AI-consent
/// gate the `InsightsStore` comprehensive load carries.
public struct MeasurementAvailabilityDTO: Codable, Sendable {
    public let summaries: [String: CountSummary]

    public init(summaries: [String: CountSummary]) {
        self.summaries = summaries
    }

    /// One per-kind summary — only `count` is read (tolerant of the slice's
    /// many other fields, which Decodable ignores). `Codable` so the SWR
    /// coordinator can round-trip it through the on-disk cache.
    public struct CountSummary: Codable, Sendable {
        public let count: Int?

        public init(count: Int?) {
            self.count = count
        }
    }
}
