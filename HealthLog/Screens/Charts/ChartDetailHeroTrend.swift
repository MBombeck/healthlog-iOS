import SwiftUI

// v0.7.0 W-API-RENDER — HeroStrip trend decoration extracted from
// `ChartDetailScreen.swift` so the host file stays under the SwiftLint
// 1000-line ceiling (handbook convention: peel sub-components into a
// sibling file rather than grow the screen file unbounded — same pattern
// as `ComplianceRingCard.swift` / `MedicationDetailSections.swift`).
//
// Both views render values the chart-detail surface used to drop on the
// floor: the comprehensive digest's per-metric 7/30/90-day regression
// slopes (`TrendSlopeRow`) and the `avg30LastYear` year-over-year baseline
// (`YearOverYearRow`). Every number is server-sourced — no on-device
// inference, per "alle Werte referenzieren, keine Halluzinationen".

// MARK: - Delta pill

/// Hero delta pill — used for both the window's change (`HeroStrip`) and the
/// year-over-year row below.
///
/// **1.5 VERDICTS (#135 rest):** the colour is the server's verdict on this
/// change (`series.change.sentiment`) and nothing else: positive green,
/// negative red, everything else neutral. The chip used to paint every rise
/// amber and every fall green, so rising steps read as a setback.
///
/// Named `HeroDeltaChip` (not `DeltaChip`) to avoid colliding with the
/// `DeltaChip` the HealthScore tile declares — both are module-visible once
/// this one moved out of `ChartDetailScreen`'s file-private scope.
struct HeroDeltaChip: View {
    let delta: Double
    let unit: String
    /// The server's verdict; `nil` → neutral.
    var sentiment: TrendSentiment?
    /// What the change compares, for VoiceOver; `nil` on the year row (its
    /// row speaks for it).
    var basis: RangeChange.Basis?

    var body: some View {
        let symbol = delta > 0 ? "arrow.up" : delta < 0 ? "arrow.down" : "minus"
        let color = Self.color(for: sentiment)

        HStack(spacing: HLSpace.xs) {
            Image(systemName: symbol)
                .font(.hlIcon(HLIconSize.xs, weight: .bold))
            Text("\(abs(delta).formatted(.number.precision(.fractionLength(0 ... 1)))) \(unit)")
                .font(.hlCaption.weight(.semibold))
                .monospacedDigit()
        }
        .foregroundStyle(color)
        .padding(.horizontal, HLSpace.sm)
        .padding(.vertical, HLSpace.xs)
        .background(color.opacity(0.18))
        .clipShape(Capsule())
        .accessibilityLabel(Text(accessibilityLabel))
    }

    /// The colour role a verdict paints (``TrendChip/Mode``'s table).
    nonisolated static func colorRole(for sentiment: TrendSentiment?) -> TrendChip.ColorRole {
        sentiment.map { TrendChip.Mode.colorRole(for: $0) } ?? .textSecondary
    }

    private static func color(for sentiment: TrendSentiment?) -> Color {
        switch colorRole(for: sentiment) {
        case .statusOK: HLColor.statusOK
        case .statusBad: HLColor.statusBad
        case .textSecondary, .none: HLText.secondary
        }
    }

    private var accessibilityLabel: String {
        let number = delta.formatted(.number.precision(.fractionLength(0 ... 1)))
        let base = switch basis {
        case .firstToLastDay: String(localized: "chart.hero.change.firstToLastDay.a11y \(number) \(unit)")
        case .priorHalf, .none: String(localized: "Delta to the previous period: \(number) \(unit)")
        }
        guard let clause = sentiment?.spokenClause else { return base }
        return "\(base), \(clause)"
    }
}

// MARK: - Trend-slope chips

/// Row of 7/30/90-day trend chips fed by the comprehensive digest's
/// per-metric regression slopes. Each chip pairs a window label ("7 T")
/// with a direction glyph. Tonal-mono per handbook §2.8 — direction is
/// communicated by the arrow glyph, not colour, so the strip reads in a
/// single neutral key alongside the rest of the chart chrome.
struct TrendSlopeRow: View {
    let slopes: [(window: ChartDetailStore.TrendWindow, slope: TrendSlope)]

    var body: some View {
        HStack(spacing: HLSpace.xs) {
            ForEach(Array(slopes.enumerated()), id: \.offset) { _, entry in
                TrendSlopeChip(window: entry.window, slope: entry.slope)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, HLSpace.xxs)
    }
}

private struct TrendSlopeChip: View {
    let window: ChartDetailStore.TrendWindow
    let slope: TrendSlope

    var body: some View {
        HStack(spacing: HLSpace.xxs) {
            Text(window.shortLabel)
                .font(.hlCaption.weight(.semibold))
                .foregroundStyle(HLText.secondary)
            Image(systemName: glyph)
                .font(.hlIcon(HLIconSize.xs, weight: .bold))
                .foregroundStyle(HLText.secondary)
        }
        .padding(.horizontal, HLSpace.sm)
        .padding(.vertical, HLSpace.xxs)
        .background(HLSurface.tertiary)
        .clipShape(Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityLabel))
    }

    /// Direction glyph. A slope without a direction never reaches a chip
    /// (#151, `ChartDetailStore.trendSlopes(from:)`): a `null` direction is
    /// "no trend", never "stable".
    private var glyph: String {
        switch slope.direction {
        case .up: "arrow.up.right"
        case .down: "arrow.down.right"
        case .stable, .none: "arrow.right"
        // #115 · 1.7 — a direction this build does not know is shown as
        // unknown, never as "stable".
        case .unknown: "questionmark"
        }
    }

    private var accessibilityLabel: String {
        let direction = switch slope.direction {
        case .up: String(localized: "rising")
        case .down: String(localized: "falling")
        case .stable, .none: String(localized: "stable")
        case .unknown: String(localized: "unknown")
        }
        return String(localized: "Trend \(window.shortLabel): \(direction)")
    }
}

// MARK: - Year-over-year row

/// "Vor 1 Jahr" baseline + delta, both sourced verbatim from the server's
/// `avg30LastYear`. The delta arrow reuses the same neutral-unless-adverse
/// `DeltaChip` discipline as the hero's prior-window delta so the two
/// readings sit consistently.
struct YearOverYearRow: View {
    let baseline: Double
    let delta: Double?
    let unit: String

    var body: some View {
        HStack(spacing: HLSpace.xs) {
            Text(String(localized: "1 year ago"))
                .font(.hlCaption)
                .foregroundStyle(HLText.tertiary)
            Text(baselineText)
                .font(.hlCaption.weight(.semibold))
                .foregroundStyle(HLText.secondary)
                .monospacedDigit()
            if let delta {
                HeroDeltaChip(delta: delta, unit: unit)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, HLSpace.xxs)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(accessibilityLabel))
    }

    private var baselineText: String {
        let value = baseline.formatted(.number.precision(.fractionLength(0 ... 1)))
        return unit.isEmpty ? value : "\(value) \(unit)"
    }

    private var accessibilityLabel: String {
        guard let delta else {
            return String(localized: "1 year ago: \(baselineText)")
        }
        let deltaText = delta.formatted(.number.precision(.fractionLength(0 ... 1)))
        return String(localized: "1 year ago: \(baselineText), change \(deltaText) \(unit)")
    }
}
