import SwiftUI

/// v0.10.0 W-Insights (R2 Phase A) — thin adapter over the unified
/// `HLMetricTile` primitive (`DesignSystem/HLMetricTile.swift`).
///
/// The canonical tile anatomy + range band + AI affordance now live in
/// `HLMetricTile`; this type is retained as the Insights-target call-site
/// shape because the grid + the customise-sheet + the Y9 tests reference its
/// `Trend.resolve(...)` / `InTargetState.resolve(...)` server-payload mappers.
/// It forwards every input straight through to `HLMetricTile`, adding the
/// optional `range` band + `onAIExplainer` slot wired by the grid.
///
/// **Anatomy / doctrine:** see `HLMetricTile` — monochrome surface, color
/// only as signal, the Blood-Pressure tile is the bar.
struct InsightsTargetTile: View {
    let iconSystemName: String
    let title: LocalizedStringKey
    /// Resolved title String for the `✦` VoiceOver label (a `LocalizedStringKey`
    /// can't be read back to a String). Defaults empty → generic AI label.
    let titleText: String
    let valueText: String
    let unitText: String?
    let sparkline: [Double]
    let trend: Trend
    let inTargetState: InTargetState
    /// One-liner under the value row ("23 of 30 days in range · Ø 30d 72,8 kg").
    /// Suppressed in `compact` layout so half-width pairs stay aligned.
    let supportLine: String?
    /// v0.10.0 — optional BP-style normalcy band (nil → no band).
    let range: RangeBand?
    let compact: Bool
    /// v0.10.0 (R2 Phase B) — per-tile AI affordance. nil → no `✦`.
    let onAIExplainer: (() -> Void)?

    init(
        iconSystemName: String,
        title: LocalizedStringKey,
        titleText: String = "",
        valueText: String,
        unitText: String? = nil,
        sparkline: [Double] = [],
        trend: Trend = .none,
        inTargetState: InTargetState = .unknown,
        supportLine: String? = nil,
        range: RangeBand? = nil,
        compact: Bool = false,
        onAIExplainer: (() -> Void)? = nil
    ) {
        self.iconSystemName = iconSystemName
        self.title = title
        self.titleText = titleText
        self.valueText = valueText
        self.unitText = unitText
        self.sparkline = sparkline
        self.trend = trend
        self.inTargetState = inTargetState
        self.supportLine = supportLine
        self.range = range
        self.compact = compact
        self.onAIExplainer = onAIExplainer
    }

    var body: some View {
        HLMetricTile(
            icon: iconSystemName,
            title: title,
            titleText: titleText,
            value: valueText,
            unit: unitText,
            trend: trend.metricTrend,
            sparkline: sparkline,
            context: supportLine,
            range: range,
            badge: inTargetState.metricBadge,
            compact: compact,
            onAIExplainer: onAIExplainer
        )
    }
}

extension InsightsTargetTile {
    /// Direction-only trend marker. Carries the server-payload `resolve(...)`
    /// mapper the grid + tests use, then bridges onto `HLMetricTile.Trend`.
    enum Trend {
        case favorable
        case adverse
        case stable
        case none

        var metricTrend: HLMetricTile.Trend {
            switch self {
            case .favorable: .favorable
            case .adverse: .adverse
            case .stable: .stable
            case .none: .none
            }
        }

        /// SF Symbol exposed for the Y9 regression tests + the customise
        /// sheet. Mirrors `HLMetricTile.Trend.symbolName`.
        var symbolName: String? {
            metricTrend.symbolName
        }

        /// Build a Trend from the API trend marker + a "lower is better"
        /// polarity flag (so `down` reads as favourable for weight + as
        /// adverse for steps).
        static func resolve(
            apiTrend: InsightsTargetsResponseDTO.TargetItem.Trend?,
            lowerIsBetter: Bool
        ) -> Trend {
            guard let apiTrend else { return .none }
            switch apiTrend {
            case .stable: return .stable
            case .up: return lowerIsBetter ? .adverse : .favorable
            case .down: return lowerIsBetter ? .favorable : .adverse
            }
        }
    }

    /// "Im Zielbereich" state — derived from the consistency strip in the API
    /// payload. Latest bucket wins. Bridges onto `HLMetricTile.InTargetState`.
    enum InTargetState: Equatable {
        case unknown
        case inBand
        case nearBand
        case outBand

        var metricBadge: HLMetricTile.InTargetState {
            switch self {
            case .unknown: .unknown
            case .inBand: .inBand
            case .nearBand: .nearBand
            case .outBand: .outBand
            }
        }

        /// Badge exposed for the Y9 regression tests. Mirrors
        /// `HLMetricTile.InTargetState.badge`.
        var badge: HLMetricTile.InTargetState.Badge? {
            metricBadge.badge
        }

        /// Pick the most recent non-nil bucket in the 7-day consistency strip
        /// and map it to the tile state. We walk from the tail backwards so
        /// weekday gaps don't drop us back to a stale reading.
        static func resolve(
            consistency7d: [InsightsTargetsResponseDTO.TargetItem.ConsistencyBucket?],
            insufficient: Bool,
            hasRange: Bool
        ) -> InTargetState {
            guard hasRange, !insufficient else { return .unknown }
            for bucket in consistency7d.reversed() {
                guard let bucket else { continue }
                switch bucket {
                case .inBand: return .inBand
                case .nearBand: return .nearBand
                case .outBand: return .outBand
                }
            }
            return .unknown
        }
    }
}

#Preview("InsightsTargetTile — Gewicht inBand") {
    InsightsTargetTile(
        iconSystemName: "scalemass",
        title: "Weight",
        valueText: "72,4",
        unitText: "kg",
        sparkline: [73.4, 73.2, 73.0, 72.9, 72.7, 72.5, 72.4],
        trend: .favorable,
        inTargetState: .inBand,
        supportLine: "Ø 30 T 72,8 kg"
    )
    .padding()
    .background(HLSurface.primary)
}
