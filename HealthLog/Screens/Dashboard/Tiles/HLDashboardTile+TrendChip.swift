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
/// Colour rules (1.5 VERDICTS, #135): the colour is the server's verdict and
/// nothing else. Favourable → `statusOK`, adverse → `statusBad`, everything
/// else (no verdict, `neutral`, `hold` with a move, an unknown word) →
/// `textSecondary`. The per-metric polarity table that used to decide
/// "adverse" on the device is no longer a colour source. Unknown trend →
/// render nothing (`EmptyView`).
///
/// Apple Health Summary tiles + Withings Health Mate both render the
/// trend the same way: arrow inline, no filled background. See R2
/// Primitive-#3 spec (lines 442-469).
struct TrendChip: View {
    enum Mode: Sendable, Equatable {
        /// No verdict from the server: direction only, monochrome.
        case neutral
        /// Which way a change counts (a target's `direction`, the snapshot's
        /// `tiles.directions` or `tiles.weightTrend`). Colour comes from
        /// ``TrendDirectionSentiment/tone(for:)`` applied to the shown arrow.
        case serverSentiment(TrendDirectionSentiment)
        /// #135 (server v1.43) — the server's verdict already applied to this
        /// card's own change (`trendSentiment`): positive green, negative red,
        /// neutral monochrome. Nothing is looked up or derived.
        case serverVerdict(TrendSentiment)
    }

    enum ColorRole: String, Sendable {
        case statusOK
        case statusBad
        case textSecondary
        case none
    }

    let trend: TrendIndicator
    let mode: Mode

    init(trend: TrendIndicator, mode: Mode = .neutral) {
        self.trend = trend
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

    var colorRole: ColorRole {
        mode.colorRole(for: trend)
    }

    var spokenClause: String? {
        mode.spokenClause(for: trend)
    }

    /// The colour a delivered verdict paints; an unknown word paints nothing.
    static func colorRole(for verdict: TrendSentiment) -> ColorRole {
        Mode.colorRole(for: verdict)
    }

    private var foregroundColor: Color {
        switch colorRole {
        case .statusOK: HLColor.statusOK
        case .statusBad: HLColor.statusBad
        case .textSecondary, .none: HLText.secondary
        }
    }
}

/// The colour table, on the value type so the pure tile resolvers (which run
/// off the main actor) read it without a view.
extension TrendChip.Mode {
    /// The colour this verdict paints on an arrow pointing `trend`.
    func colorRole(for trend: TrendIndicator) -> TrendChip.ColorRole {
        guard let change = Self.change(for: trend) else { return .none }
        switch self {
        case .neutral:
            return .textSecondary
        case let .serverSentiment(sentiment):
            switch sentiment.tone(for: change) {
            case .favorable: return .statusOK
            case .adverse: return .statusBad
            case .neutral: return .textSecondary
            }
        case let .serverVerdict(verdict):
            return Self.colorRole(for: verdict)
        }
    }

    /// The verdict the colour shows, in words for VoiceOver. `nil` when the
    /// arrow is monochrome: nothing to add.
    func spokenClause(for trend: TrendIndicator) -> String? {
        switch colorRole(for: trend) {
        case .statusOK: TrendSentiment.positive.spokenClause
        case .statusBad: TrendSentiment.negative.spokenClause
        case .textSecondary, .none: nil
        }
    }

    static func colorRole(for verdict: TrendSentiment) -> TrendChip.ColorRole {
        switch verdict {
        case .positive: .statusOK
        case .negative: .statusBad
        case .neutral, .unknown: .textSecondary
        }
    }

    /// The observed direction in the sentiment table's vocabulary.
    static func change(for trend: TrendIndicator) -> TrendDirectionSentiment.Change? {
        switch trend {
        case .up: .rising
        case .down: .falling
        case .flat: .level
        case .unknown: nil
        }
    }
}

extension DashboardMetric {
    /// Direction shown by dashboard surfaces: the server's, as sent. Without
    /// one the tile shows no arrow. Steps and sleep used to derive a direction
    /// from the first and last sparkline point (weight until #115 · 1.1); that
    /// guess is gone since #115 B7.
    var dashboardTrend: TrendIndicator {
        trend
    }

    /// VoiceOver hears the verdict the colour shows ("Trend rising, a good
    /// direction for you"). Empty when the arrow is monochrome.
    func spokenVerdictSuffix(_ verdicts: TileTrendVerdicts) -> String {
        verdicts.mode(for: self).spokenClause(for: trend).map { ", \($0)" } ?? ""
    }

    /// The spoken direction plus the verdict, for surfaces whose label did not
    /// speak a trend before v1.43. `nil` without a verdict colour (the label
    /// stays as it was) or without a known direction.
    func spokenTrendWithVerdict(_ verdicts: TileTrendVerdicts) -> String? {
        guard let clause = verdicts.mode(for: self).spokenClause(for: trend) else { return nil }
        let direction: String? = switch trend {
        case .up: String(localized: "Trend rising")
        case .down: String(localized: "Trend falling")
        case .flat: String(localized: "Trend stable")
        case .unknown: nil
        }
        return direction.map { "\($0), \(clause)" }
    }
}
