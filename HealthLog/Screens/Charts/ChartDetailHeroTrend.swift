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

/// Hero delta pill — used for both the prior-window delta (`HeroStrip`) and
/// the v0.7.0 W-API-RENDER year-over-year row below. Neutral unless the
/// delta is meaningful, then green (improvement) / amber (regression).
///
/// Named `HeroDeltaChip` (not `DeltaChip`) to avoid colliding with the
/// `DeltaChip` the HealthScore tile declares — both are module-visible once
/// this one moved out of `ChartDetailScreen`'s file-private scope.
struct HeroDeltaChip: View {
    let delta: Double
    let unit: String

    var body: some View {
        let symbol = delta > 0 ? "arrow.up" : delta < 0 ? "arrow.down" : "minus"
        let color: Color = if abs(delta) < 0.05 {
            HLText.secondary
        } else if delta > 0 {
            HLColor.statusWarn
        } else {
            HLColor.statusOK
        }

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
        .accessibilityLabel(Text("Delta to the previous period: \(delta.formatted(.number.precision(.fractionLength(0 ... 1)))) \(unit)"))
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

    /// Direction glyph — `nil` server direction collapses to the flat
    /// "stable" minus so a missing field never blanks the chip.
    private var glyph: String {
        switch slope.direction {
        case .up: "arrow.up.right"
        case .down: "arrow.down.right"
        case .stable, .none: "arrow.right"
        }
    }

    private var accessibilityLabel: String {
        let direction = switch slope.direction {
        case .up: String(localized: "rising")
        case .down: String(localized: "falling")
        case .stable, .none: String(localized: "stable")
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
