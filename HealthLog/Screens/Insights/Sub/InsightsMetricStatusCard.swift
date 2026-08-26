import SwiftUI

/// v0.14.3 C4 — the **ONE canonical "30 Tage Durchschnitt" status card** rendered
/// on EVERY per-metric Insights page (Blutdruck, Puls, Gewicht, BMI, Ruhepuls, …).
///
/// Before this, the per-metric primary card forked on `kind == .bloodPressure`:
/// BP rendered the rich `BPStatusCard` (assessment chip + 30-day average +
/// "Im Zielbereich" bar + Zielband), while every OTHER metric rendered the thin
/// `InsightsPrimaryTile` (a bare number, `pctInTarget` hard-coded `nil`). The
/// operator flagged repeatedly that "Puls looks completely different from
/// Blutdruck". This card collapses both into a single primitive so the two can
/// never drift again — the BP anatomy IS the canonical anatomy.
///
/// **Driven by a pure ``Descriptor``** so the screen builds the descriptor from
/// the server `comprehensive` digest + the targets payload and the card just
/// renders it. The descriptor is honest-only: each optional slot
/// (classification chip, headline, in-target bar, Zielband caption) is `nil`
/// when the server carries no signal, so a sparse metric renders a clean,
/// reduced card — never an empty chip, never a fake "Im Zielbereich".
///
/// **Anatomy (lifted verbatim from the retired `BPStatusCard`):**
///   1. header row — title + optional guideline caption (BP "ESH 2023") +
///      `Spacer` + optional classification chip (`HLBadge`) top-right;
///   2. headline value — the 30-day average (BP: sys/dia pair) + unit caption;
///   3. the shared `InsightsInTargetBar` ("Im Zielbereich"), when a pct exists;
///   4. the Zielband caption, when a target band exists.
///
/// **C2:** the in-card "· 30-day avg" hint was removed from the unit caption —
/// the screen now renders a "30 Tage Durchschnitt" section heading ABOVE the
/// card, so repeating it inside is redundant.
///
/// **Monochrome doctrine:** the only colour is the chip tone + the in-target
/// fill/percentage (both signal-only, tokenized); everything else rides the
/// `HLText.*` scale on a matte `HLCard`.
struct InsightsMetricStatusCard: View {
    /// Pure, value-typed render input. Built by the screen from the server
    /// digest + targets payload; testable without standing up SwiftUI.
    struct Descriptor: Equatable {
        /// Localized metric title (`kind.displayName`).
        let title: String
        /// Optional guideline caption next to the title (BP → "ESH 2023").
        let guidelineCaption: LocalizedStringKey?
        /// The classification / assessment chip text (e.g. "Hoch-normal",
        /// "Normalgewicht"). `nil` → no chip (honest self-suppression).
        let chipLabel: String?
        /// The chip tone (signal-only). Ignored when `chipLabel == nil`.
        let chipTone: HLBadge.Tone
        /// The pre-formatted headline value (BP → "128/82"; others → the 30-day
        /// average or, honestly, the latest reading). `nil` → no headline.
        let headlineValue: String?
        /// The unit caption under/after the headline (e.g. "mmHg", "kg").
        let unitCaption: String
        /// Server-provided in-target share (0…100). `nil` → no "Im Zielbereich"
        /// bar (no client recompute beyond the day-share the server emits).
        let pctInTarget: Int?
        /// b183 coherence — the window `pctInTarget` is measured over ("90 T" for
        /// BP's server `bpPctInTarget`, "30 T" for the locally-computed non-BP
        /// share). Surfaced on the bar so the figure isn't read as a different
        /// window. `nil` → no window suffix.
        var inTargetWindowLabel: String?
        /// The Zielband caption ("Ziel: 120–129 mmHg"). `nil` → no band line.
        let targetBandCaption: String?
        /// v0.14.4 D1 — a target-less **Verlauf** sparkline for kinds the server
        /// emits no clinical band for (Aktive Energie + the other ~25 non-targeted
        /// kinds, plus BMI). Honest: a trend line only, never a fabricated Zielband
        /// or "Im Zielbereich" bar. `nil` → no sparkline (the targeted kinds keep
        /// their full chip+band+bar anatomy and don't double up a trend line here).
        let sparklineValues: [Double]?
        /// Accessibility-identifier suffix (the metric `rawValue`).
        let identifierSuffix: String

        /// True when the descriptor carries at least one renderable slot — the
        /// card self-suppresses entirely when every slot is empty (a metric with
        /// no digest + no target reads as a clean heading + chart, no empty card).
        var hasAnyContent: Bool {
            chipLabel != nil
                || headlineValue != nil
                || pctInTarget != nil
                || targetBandCaption != nil
                || showsSparkline
        }

        /// v0.14.4 D1 — render the target-less Verlauf only when there is no
        /// "Im Zielbereich" bar (targeted kinds already carry the richer in-target
        /// fill; a sparkline would be redundant) AND at least two points exist.
        var showsSparkline: Bool {
            pctInTarget == nil && (sparklineValues?.count ?? 0) >= 2
        }
    }

    let descriptor: Descriptor

    var body: some View {
        if descriptor.hasAnyContent {
            HLCard {
                VStack(alignment: .leading, spacing: HLSpace.sm) {
                    headerRow
                    headlineRow
                    if let pct = descriptor.pctInTarget {
                        InsightsInTargetBar(pct: pct, windowLabel: descriptor.inTargetWindowLabel)
                    }
                    if let band = descriptor.targetBandCaption {
                        Text(band)
                            .font(.hlCaption)
                            .foregroundStyle(HLText.tertiary)
                    }
                    // v0.14.4 D1 — the target-less Verlauf. Monochrome (no tone:
                    // there is no clinical band → no in/out-of-band colour), so the
                    // line rides the neutral series tint. Only paints for the
                    // non-targeted kinds (BMI + Aktive Energie + …) that the
                    // operator flagged as "der Verlauf ist nicht mitgekommen".
                    if descriptor.showsSparkline, let values = descriptor.sparklineValues {
                        HLSparkline(values: values, tint: HLText.secondary)
                            .frame(height: 40)
                            .accessibilityLabel(Text("Trend"))
                    }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("insights.metric.statusCard.\(descriptor.identifierSuffix)")
        }
    }

    private var headerRow: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(descriptor.title)
                .font(.hlCaption.weight(.semibold))
                .foregroundStyle(HLText.secondary)
            if let guideline = descriptor.guidelineCaption {
                Text(guideline)
                    .font(.hlCaption)
                    .foregroundStyle(HLText.tertiary)
            }
            Spacer()
            // C3 — the chip lives in the header row. Both the Letzte-Messung
            // delta tick (HeroDeltaChip, pinned to the top of its HStack) and
            // this chip now anchor to the top of their respective cards' header
            // rows, so they sit at the SAME vertical position across both cards.
            if let chipLabel = descriptor.chipLabel {
                HLBadge(chipLabel, tone: descriptor.chipTone)
            }
        }
    }

    @ViewBuilder
    private var headlineRow: some View {
        if let value = descriptor.headlineValue {
            HStack(alignment: .firstTextBaseline, spacing: HLSpace.xs) {
                Text(value)
                    .font(.hlMetric(.largeTitle))
                    .foregroundStyle(HLText.primary)
                    .monospacedDigit()
                    .minimumScaleFactor(0.75)
                // C2 — unit only; the "· 30-day avg" hint moved to the section
                // heading the screen renders ABOVE this card.
                if !descriptor.unitCaption.isEmpty {
                    Text(descriptor.unitCaption)
                        .font(.hlCaption)
                        .foregroundStyle(HLText.tertiary)
                }
            }
        }
    }
}
