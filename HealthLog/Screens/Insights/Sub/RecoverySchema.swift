import SwiftUI

/// **C3 — the recovery family, rendered in the canonical metric vocabulary, to
/// the extent its data honestly allows.**
///
/// The operator's complaint is precise: „Erholung folgt nicht dem Schema von
/// Blutdruck und Puls. Vereinbart war, dass es überall gleich aussieht: letzte
/// Messungen, 30-Tage-Durchschnitt mit Pfeil, ‚on target'. Aktuell nur nackte
/// Momentanwerte ohne Kontext und ohne Verlauf." The canonical shape he is
/// comparing against — `InsightsMetricScreen` + `InsightsMetricStatusCard` —
/// exists because of an *earlier, identical* complaint („Puls sieht anders aus
/// als Blutdruck"), which is why answering this one with a bespoke recovery
/// layout would be the wrong answer twice.
///
/// So this type builds the canonical `Descriptor` and does not fork the card.
///
/// **What the data allows, field by field.** `RecoveryInsightsDTO.Item` carries
/// `score`, `value`, `unit`, `band`, `trendDelta` and `reason` — and nothing
/// else. There is no series, no aggregate, no target band, and no window label
/// anywhere in the payload; `/api/insights/recovery` has never existed on any
/// server version this app has talked to, and the family arrives inside the
/// health-score response.
///
/// | Descriptor slot | Recovery | Why |
/// |---|---|---|
/// | `headlineValue` | latest reading / composite | the only number the server sends |
/// | `unitCaption` | server `unit`, verbatim | never converted |
/// | `chipLabel` / `chipTone` | from `band` | this IS the family's „on target" |
/// | `pctInTarget` | **nil** | no in-target share is published |
/// | `inTargetWindowLabel` | **nil** | there is no window to name |
/// | `targetBandCaption` | **nil** | no band is published |
/// | `sparklineValues` | **nil** | no series is published |
///
/// **The empty slots are the deliverable, not a shortfall in it.** The canonical
/// card already self-suppresses per slot (`hasAnyContent`, `showsSparkline`), so
/// recovery gets the family's anatomy for exactly the parts it can back and
/// silence for the rest — instead of a 30-day arrow over a window the data does
/// not cover, which would be consistency achieved by lying.
///
/// What is still missing is asked once, in the C3/C4 server ask that covers both
/// clients (`SERVER-ROUTING.md`), not invented here.
enum RecoverySchema {
    /// The canonical status descriptor for one recovery item, or `nil` when the
    /// item carries nothing renderable (no score, no value) — the same
    /// honest-only rule the page already applies.
    static func descriptor(for item: RecoveryInsightsDTO.Item) -> InsightsMetricStatusCard.Descriptor? {
        guard let headline = headlineValue(for: item) else { return nil }
        return InsightsMetricStatusCard.Descriptor(
            title: RecoveryFamilyLabels.label(for: item),
            guidelineCaption: nil,
            chipLabel: chipLabel(for: item),
            chipTone: chipTone(for: item),
            headlineValue: headline,
            unitCaption: item.score != nil ? "" : (item.unit ?? ""),
            pctInTarget: nil,
            inTargetWindowLabel: nil,
            targetBandCaption: nil,
            sparklineValues: nil,
            identifierSuffix: "recovery.\(item.id)"
        )
    }

    /// The latest reading, formatted the way the page already formats it: a
    /// composite renders as a whole 0–100 score, a stat renders its server value
    /// with at most one fractional digit. `nil` when the server sent neither.
    ///
    /// **This is a latest reading and it is never called an average.** The
    /// canonical card's own doc allows exactly this („the 30-day average or,
    /// honestly, the latest reading"), which is why the family vocabulary can be
    /// adopted at all without a server change.
    static func headlineValue(for item: RecoveryInsightsDTO.Item) -> String? {
        if let score = item.score, score.isFinite {
            return Int(safeServer: score).map { "\($0)" } ?? HLNumberFormat.decimal(score, fractionDigits: 1)
        }
        guard let value = item.value, value.isFinite else { return nil }
        if value == value.rounded(), let whole = Int(safeServer: value) {
            return "\(whole)"
        }
        return HLNumberFormat.decimal(value, fractionDigits: 1)
    }

    /// The family's „on target": the server `band`, resolved through the SAME
    /// seam the recovery rings already use (`HLScoreRing.ScorePresentation`), so
    /// a band means the same thing on both archetypes and an unrecognised band
    /// produces no chip on either. Never a fabricated classification.
    static func chipLabel(for item: RecoveryInsightsDTO.Item) -> String? {
        switch HLScoreRing.ScorePresentation.signal(forBand: item.band) {
        case .ok: String(localized: "insights.recovery.band.onTarget")
        case .warn: String(localized: "insights.recovery.band.watch")
        case .bad: String(localized: "insights.recovery.band.offTarget")
        default: nil
        }
    }

    static func chipTone(for item: RecoveryInsightsDTO.Item) -> HLBadge.Tone {
        switch HLScoreRing.ScorePresentation.signal(forBand: item.band) {
        case .ok: .success
        case .warn: .warning
        case .bad: .critical
        default: .neutral
        }
    }

    /// **The honesty gate, stated structurally rather than computed.**
    ///
    /// A windowed claim („30-Tage-Durchschnitt", „im Zielbereich über 90 T")
    /// needs either a series or an explicitly labelled aggregate to stand on.
    /// `RecoveryInsightsDTO.Item` publishes **neither** — its whole surface is
    /// `id`, `label`, `value`, `unit`, `score`, `band`, `trendDelta`, `reason` —
    /// so no payload from any server version this app has met could back one.
    /// That is a fact about the contract, not about a particular response, which
    /// is why it is a constant and not a fold over the items.
    ///
    /// `RecoverySchemaAdoptionTests` pins it against the DTO's own field list, so
    /// the day the server publishes an aggregate and the DTO grows the field,
    /// this constant fails instead of quietly staying wrong.
    static let publishesWindowedAggregate = false
}
