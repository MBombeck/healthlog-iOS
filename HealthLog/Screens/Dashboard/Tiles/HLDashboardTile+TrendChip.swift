import SwiftUI

// MARK: - Trend chip

/// Inline trend glyph — arrow only, no background fill.
///
/// Split out of `HLDashboardTile.swift` (v0.16 Build 7 / item 7.1) so that file
/// stays under the `file_length` budget after the 7-/30-day-average additions.
///
/// **Theme C-5 (2026-05-16, R1-Strategy-C + R2 Primitive-#3):** flattened
/// from a filled-circle pill (`color.opacity(0.18)` background, padded
/// arrow) to a flat inline glyph. Driver: the operator's design
/// philosophy ("cool/schlicht/minimalistisch, nicht so Akzentfarben, keine
/// Gamification, Withings-Reference") plus the cross-dashboard load of
/// 8+ tinted pills painting the grid as visual noise (R5 felt-UX audit).
///
/// Colour rules:
/// - **Adverse trend** (up on `lowerIsBetter` / down on `higherIsBetter`)
///   → `statusBad` (Dracula-red) — the only retained colour, per R5 a11y
///   mitigation so trend direction stays legible to non-colour-aware
///   users without leaning on green/red duality.
/// - **Favorable + flat + neutral trend** → `textSecondary` — monochrome,
///   reads as "trend present but not alarming".
/// - **Unknown trend** → render nothing (`EmptyView`). Empty-state tiles
///   no longer show a `?` chip — silence is the calmer signal.
///
/// Apple Health Summary tiles + Withings Health Mate both render the
/// trend the same way: arrow inline, no filled background. See R2
/// Primitive-#3 spec (lines 442-469).
///
/// `TrendIndicator` carries direction-only — no numeric delta — so the
/// chip is glyph-only for now. The R2-spec'd `↑ +1.2%` inline delta-text
/// is deferred until the model gains a `delta` field (out of scope for
/// C-5 per the file-disjoint contract).
struct TrendChip: View {
    enum Mode: Sendable, Equatable {
        /// Existing clinical presentation: only adverse movement is red.
        case polarityAware
        /// Dashboard-only literal presentation requested by the operator.
        case dashboardDirection
    }

    enum ColorRole: String, Sendable {
        case statusOK
        case statusBad
        case textSecondary
        case none
    }

    let trend: TrendIndicator
    let polarity: MetricKindDescriptor.TrendPolarity
    let mode: Mode

    init(
        trend: TrendIndicator,
        polarity: MetricKindDescriptor.TrendPolarity,
        mode: Mode = .polarityAware
    ) {
        self.trend = trend
        self.polarity = polarity
        self.mode = mode
    }

    var body: some View {
        if let symbolName {
            Image(systemName: symbolName)
                // swiftlint:disable:next dynamic_type_bypass
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(foregroundColor)
                .accessibilityHidden(true) // surfaced via the parent label
        }
    }

    /// `nil` → render nothing (unknown trends suppress the chip entirely).
    private var symbolName: String? {
        switch trend {
        case .up: "arrow.up"
        case .down: "arrow.down"
        case .flat: "minus"
        case .unknown: nil
        }
    }

    /// Adverse for the metric's polarity (up on `lowerIsBetter` / down on
    /// `higherIsBetter`) → `statusBad`. Everything else is monochrome — the
    /// legacy `statusOK` (green) branch is gone so the grid no longer
    /// alternates green/red across tiles (Theme-2.0 T2-2 / C-5).
    var isAdverse: Bool {
        switch (trend, polarity) {
        case (.up, .lowerIsBetter), (.down, .higherIsBetter):
            true
        default:
            false
        }
    }

    var colorRole: ColorRole {
        guard trend != .unknown else { return .none }
        switch mode {
        case .polarityAware:
            return isAdverse ? .statusBad : .textSecondary
        case .dashboardDirection:
            switch trend {
            case .up: return .statusOK
            case .down: return .statusBad
            case .flat: return .textSecondary
            case .unknown: return .none
            }
        }
    }

    private var foregroundColor: Color {
        switch colorRole {
        case .statusOK: HLColor.statusOK
        case .statusBad: HLColor.statusBad
        case .textSecondary, .none: HLText.secondary
        }
    }
}

extension DashboardMetric {
    /// Direction shown by dashboard surfaces. The server wins whenever it has
    /// a direction; otherwise only weight, steps, and sleep derive one from the
    /// bounded visible sparkline.
    var dashboardTrend: TrendIndicator {
        DashboardStore.dashboardTrend(server: trend, kind: kind, visibleValues: sparkline)
    }

    /// Literal green/up and red/down is scoped to the three requested Home
    /// metrics. Every other kind retains the established polarity-aware mode.
    var dashboardTrendMode: TrendChip.Mode {
        [.weight, .steps, .sleep].contains(kind) ? .dashboardDirection : .polarityAware
    }
}
