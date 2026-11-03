import SwiftUI

// v0.11 W22-W2 — the Min / Ø / Max / Median row of the metric page, lifted out
// of `ChartDetailComponents.swift` (1.4 B2, file_length: pure code movement).

// MARK: - Stats summary row (Apple-Health-style)

/// Four-card statistic summary — Min, Ø (mean), Max, Median.
///
/// Median is the additive Charlie-v0.4.0 stat (the prior row showed σ, which
/// is information-dense but less actionable for end users; Apple Health uses
/// Min/Avg/Max + an "Auf einen Blick" median-equivalent). Median is computed
/// on-device from the rendered series via `ChartDetailStore.median`. σ stays
/// available in `SeriesStats` for future deep-dives but isn't surfaced here.
struct StatsRow: View {
    let stats: SeriesStats?
    let median: Double?
    let unit: String
    /// A360-5 C-1 — the metric kind drives unit conversion of the stats. Default
    /// `nil` keeps existing call-sites compiling and renders the raw value (the
    /// pre-fix behaviour) until they pass a kind; the in-app call-sites all pass
    /// it so weight/BP convert. Glucose stats are already server-converted.
    var kind: MetricKind?
    var units: UnitPreferences = .standard

    var body: some View {
        if let stats {
            HStack(spacing: HLSpace.sm) {
                StatBox(label: String(localized: "Min"), value: format(stats.min), unit: unit)
                StatBox(label: String(localized: "chart.stat.mean"), value: format(stats.mean), unit: unit)
                StatBox(label: String(localized: "Max"), value: format(stats.max), unit: unit)
                if let median {
                    StatBox(label: String(localized: "chart.stat.median"), value: format(median), unit: unit)
                }
            }
            .accessibilityElement(children: .contain)
        }
    }

    /// Converts a stat into the user's unit. Series stats are canonical for
    /// weight/BP (convert) and already server-converted for glucose (pass
    /// through), mirroring the hero/point formatter. Falls back to the prior
    /// raw 0…1-dp rendering when no `kind` is supplied.
    ///
    /// **BH-final-diff H6/M5** — the precision per family must match the
    /// hero/callout EXACTLY so the same chart screen never disagrees with
    /// itself. Weight uses 1-dp (the dashboard/hero canonical `fractionLength(1)`
    /// → `80.0`); BP is integer-grained for mmHg and 1-dp for kPa (a single
    /// leg's value, since the stats row renders systolic/diastolic separately).
    private func format(_ v: Double) -> String {
        guard let kind else {
            return v.formatted(.number.precision(.fractionLength(0 ... 1)))
        }
        // #115 P2 — one central account-unit formatter. Series glucose is
        // already server-converted (passed through); every other family
        // converts from canonical SI; the identity branch keeps 0…1 dp.
        // BP renders one leg at a time here: mmHg integer, kPa 1-dp.
        return MetricValueFormatter.account(v, kind: kind, units: units, glucose: .seriesPreConvertedGlucose) {
            $0.formatted(.number.precision(.fractionLength(0 ... 1)))
        }
    }
}

/// **v0.6.1.6 — Y6 — AP-005.** Min / Ø / Max / Median pills routed onto
/// the Tonal-Mono `HLText.*` scale per handbook §2.8 — value `.primary`,
/// label `.secondary`, unit `.tertiary`. Operator quote: *"bei Min, Max,
/// Median und oben wo ich den Zeitraum auswählen kann, das sind so
/// dunkelblaue Elemente … Das sollte alles in diesem Schwarz sein."* The
/// prior `HLText.primary` Dracula-tinted asset read as a faint
/// purple-blue on the headline-weight value glyph. Pill background locks
/// to `HLSurface.tertiary` (canonical recessed-well surface).
struct StatBox: View {
    let label: String
    let value: String
    let unit: String

    var body: some View {
        VStack(spacing: HLSpace.xxs) {
            // A2 (v0153 a11y MEDIUM) — up to 4 boxes share a 393 pt row (~90 pt
            // each), doubled on the BP systolic/diastolic strip. At AX4/AX5 the
            // caption/value/unit would wrap or clip silently; clamp to one line
            // and scale down instead of truncating.
            Text(label).font(.hlCaption).foregroundStyle(HLText.secondary)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(value).font(.hlMetric(.headline)).foregroundStyle(HLText.primary).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(unit).font(.hlCaption).foregroundStyle(HLText.tertiary)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, HLSpace.sm)
        .background(HLSurface.tertiary)
        .clipShape(RoundedRectangle(cornerRadius: HLRadius.sm, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(label) \(value) \(unit)"))
    }
}
