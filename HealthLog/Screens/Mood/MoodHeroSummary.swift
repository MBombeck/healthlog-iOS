import SwiftUI

/// v0.10.0 W-Mood-A — zone-1 hero summary (DESIGN-A §1.3).
///
/// "Here is how you feel now": latest mood (big value) + 30-day average + the
/// prior-period trend as a calm caption line.
///
/// **I-4 Item 2 (standardisation):** the card was reworked to read like every
/// other Insights card (`InsightsPrimaryTile` / `BPStatusCard`): a
/// secondary-caption heading, the big headline value, and the trend folded into
/// a single bottom **caption line with a leading direction glyph** — instead of
/// the old free-floating `arrow.up.right` glyph parked in the value row, which
/// the operator flagged as "not conform with the other cards". The trend
/// direction still reads (the small glyph IN the caption), but there is no
/// off-pattern arrow affordance any more. Monochrome.
///
/// 1.5 VERDICTS (#151) — the glyph points where the server's trend points
/// (`direction` of the 30-day slope, else the 7-day one) and nowhere else: no
/// slope from the server, no arrow. It no longer warms on a fall either; that
/// was the app's own judgement.
///
/// POLISH-B B8 (VERDICTS 6.4) — the glyph takes its colour from the server's
/// verdict for mood (`tiles.directions["MOOD"]` of the dashboard snapshot,
/// v1.43), the same rule as the trend arrows on Today: rising mood with
/// `up-good` is green, falling red. Without a verdict it stays one quiet
/// colour, as before.
struct MoodHeroSummary: View {
    let insights: MoodInsights
    /// The server's verdict for mood; `nil` on an older server or before the
    /// snapshot loaded.
    var verdict: TrendDirectionSentiment?

    var body: some View {
        HLCard {
            // v0.14.7 B5 — the "Stimmung heute" title moved OUT of the card to a
            // section heading above it (`MoodAnalysisContent` section 0); the
            // card now leads with the value, matching the metric tiles.
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                HStack(alignment: .firstTextBaseline, spacing: HLSpace.md) {
                    Text(latestLabel)
                        // Audit-01 H3 — semantic metric style (28pt @ Large)
                        // instead of the pixel-locked escape hatch, so the hero
                        // value scales with Dynamic Type.
                        .font(.hlMetric(.title))
                        .foregroundStyle(HLText.primary)
                        // 1.4 B4 — wraps at large text sizes instead of
                        // shrinking the one figure the card exists for.
                        .fixedSize(horizontal: false, vertical: true)
                    if let avg30 = insights.avg30 {
                        Text("Ø 30d \(avg30.formatted(.number.precision(.fractionLength(1))))")
                            .font(.hlSubhead)
                            .foregroundStyle(HLText.secondary)
                            .monospacedDigit()
                    }
                    Spacer(minLength: 0)
                }

                trendLine
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Current mood"))
        .accessibilityValue(Text(accessibilityValue))
    }

    private var latestLabel: String {
        guard let score = insights.latestScore else { return "—" }
        return MoodCopy.scoreLabel(score)
    }

    /// I-4 Item 2 — the trend, rendered as ONE calm caption line (leading
    /// direction glyph + the "+0.4 vs last month" delta), so the card matches
    /// the canonical "heading → value → caption" anatomy. Omitted when there is
    /// neither a slope nor a prior-period delta. The glyph is monochrome.
    ///
    /// 1.4 B4 — the glyph only leads a delta. Without one it stood alone on
    /// its own line under the value, an arrow that pointed at nothing.
    @ViewBuilder
    private var trendLine: some View {
        if let deltaLine {
            HStack(spacing: HLSpace.xs) {
                if let symbol = Self.symbol(for: insights.trendDirection) {
                    Image(systemName: symbol)
                        .font(.hlCaption.weight(.semibold))
                        .foregroundStyle(Self.glyphColor(Self.glyphRole(direction: insights.trendDirection, verdict: verdict)))
                        .accessibilityHidden(true)
                }
                Text(deltaLine)
                    .font(.hlCaption)
                    .foregroundStyle(HLText.tertiary)
                    .monospacedDigit()
            }
        }
    }

    /// "+0.4 vs last month" line — omitted when there's no prior period.
    private var deltaLine: String? {
        guard let avg30 = insights.avg30, let prior = insights.avg30PriorPeriod else { return nil }
        let delta = avg30 - prior
        let magnitude = abs(delta).formatted(.number.precision(.fractionLength(1)))
        let signed = delta >= 0 ? "+\(magnitude)" : "−\(magnitude)"
        return String(localized: "\(signed) vs last month")
    }

    private var accessibilityValue: String {
        var parts: [String] = []
        if let score = insights.latestScore {
            parts.append(String(localized: "Latest \(MoodCopy.scoreLabel(score))"))
        }
        if let avg30 = insights.avg30 {
            parts.append(String(localized: "30-day average \(avg30.formatted(.number.precision(.fractionLength(1))))"))
        }
        if let dir = Self.spokenDirection(insights.trendDirection) {
            parts.append(String(localized: "trend \(dir)"))
            if let clause = Self.spokenVerdict(direction: insights.trendDirection, verdict: verdict) {
                parts.append(clause)
            }
        }
        if let line = deltaLine { parts.append(line) }
        return parts.joined(separator: ". ")
    }

    /// The server's direction as a glyph; `nil` (no trend, or a word this
    /// build does not know) draws none.
    nonisolated static func symbol(for direction: TrendDirection?) -> String? {
        switch direction {
        case .up: "arrow.up.right"
        case .down: "arrow.down.right"
        case .stable: "arrow.right"
        case .unknown, .none: nil
        }
    }

    /// POLISH-B B8 — the server's mood direction as the arrow vocabulary of
    /// the tiles.
    nonisolated static func indicator(for direction: TrendDirection?) -> TrendIndicator? {
        switch direction {
        case .up: .up
        case .down: .down
        case .stable: .flat
        case .unknown, .none: nil
        }
    }

    /// The glyph's colour role: the verdict's, judged the way Today judges its
    /// arrows (``TrendChip/Mode/serverSentiment(_:)``); without a verdict the
    /// quiet secondary colour.
    static func glyphRole(direction: TrendDirection?, verdict: TrendDirectionSentiment?) -> TrendChip.ColorRole {
        guard let verdict, verdict != .unknown, let trend = indicator(for: direction) else { return .textSecondary }
        let role = TrendChip.Mode.serverSentiment(verdict).colorRole(for: trend)
        return role == .none ? .textSecondary : role
    }

    static func spokenVerdict(direction: TrendDirection?, verdict: TrendDirectionSentiment?) -> String? {
        guard let verdict, verdict != .unknown, let trend = indicator(for: direction) else { return nil }
        return TrendChip.Mode.serverSentiment(verdict).spokenClause(for: trend)
    }

    private static func glyphColor(_ role: TrendChip.ColorRole) -> Color {
        switch role {
        case .statusOK: HLColor.statusOK
        case .statusBad: HLColor.statusBad
        case .textSecondary, .none: HLText.secondary
        }
    }

    nonisolated static func spokenDirection(_ direction: TrendDirection?) -> String? {
        switch direction {
        case .up: String(localized: "rising")
        case .down: String(localized: "falling")
        case .stable: String(localized: "steady")
        case .unknown, .none: nil
        }
    }
}
