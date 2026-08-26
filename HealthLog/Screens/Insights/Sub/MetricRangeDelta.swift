import SwiftUI

/// W5-3 (v0.12 W5a) — the **period-over-period delta caption** on the web-mirror
/// per-metric Insights page, the iOS twin of the web `MetricRangeDelta`
/// (`src/components/insights/metric-range-delta.tsx`). Web pairs the range pills
/// with a "+3% vs prior 30d" caption carrying metric-aware sentiment colour; iOS
/// had the range control (`HLFloatingPeriodControl`) but no delta.
///
/// **Data source — client-side, NO new server contract (STANDARDS §3):** the
/// delta is computed from the SAME `[SeriesPoint]` the chart already loaded for
/// the selected range. The loaded window is split at its temporal midpoint into
/// a *prior* half and a *current* half; the delta is `mean(current) −
/// mean(prior)`, rendered as a signed percentage of the prior mean. This needs
/// no extra round-trip and no analytics endpoint — it reads what is already on
/// screen. (The web keys its delta to a server analytics-range window; the iOS
/// honest equivalent over the on-device series is the in-window split.)
///
/// **Sentiment (mirrors web rules; rendered through the app's MONOCHROME tile
/// grammar):**
/// - `higherIsBetter` → a rise is favourable, a fall adverse.
/// - `lowerIsBetter` → a fall is favourable, a rise adverse.
/// - `neutral` (and every target-band metric) → ALWAYS neutral, direction shown
///   but never tinted as good/bad.
/// Colour stays signal-only and follows the canonical tile/`TrendChip` grammar
/// (STANDARDS §7): **only an ADVERSE delta carries colour** (`HLColor.statusBad`,
/// the lone signal tint trend glyphs use); favourable + neutral deltas render
/// monochrome (`HLText.secondary`). We do NOT reintroduce a green "good" tint —
/// the `statusOK`-green branch was intentionally retired from the tile grammar
/// (T2-2/C-5) so the metric column never alternates green/red. The sentiment is
/// still computed (web parity + accessibility + tests); it just maps favourable
/// onto the calm mono treatment.
///
/// **Self-suppression (calm doctrine):** with no prior-window data — fewer than
/// two points in either half, or a zero/▏undefined prior mean — the view renders
/// **nothing** (no "—", no apologetic empty caption). A sparse metric simply
/// shows the range control with no delta line.
struct MetricRangeDelta: View {
    /// The chart's loaded points for the selected range (chronological or not —
    /// the resolver sorts by date internally).
    let points: [SeriesPoint]
    /// The metric's polarity — drives the sentiment colour (target-band metrics
    /// pass `.neutral`).
    let polarity: MetricKindDescriptor.TrendPolarity
    /// The selected range, supplying the "vs prior <label>" suffix.
    let range: ChartDetailStore.Range

    var body: some View {
        if let result = Self.resolve(points: points, polarity: polarity) {
            HStack(spacing: HLSpace.xxs) {
                Image(systemName: result.symbol)
                    .accessibilityHidden(true)
                Text(result.deltaText)
                    .monospacedDigit()
                Text(priorLabel)
            }
            .font(.hlCaption)
            .foregroundStyle(result.tint)
            .lineLimit(1)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(accessibilityText(result)))
            .accessibilityIdentifier("insights.metric.rangeDelta")
        }
    }

    /// "vs prior <range>" suffix — the prior-window label localized off the
    /// selected range's accessibility name (e.g. "vs prior month").
    private var priorLabel: String {
        String(localized: "insights.metric.rangeDelta.priorSuffix \(range.accessibilityLabel.lowercased())")
    }

    private func accessibilityText(_ result: Result) -> String {
        "\(result.deltaText) \(priorLabel)"
    }

    // MARK: - Pure resolution

    /// One resolved delta. `nonisolated` so the pure math is unit-testable
    /// without a SwiftUI host.
    nonisolated struct Result: Equatable {
        /// Signed percentage string, e.g. "+3%" / "−1.4%" / "±0%".
        let deltaText: String
        /// SF Symbol for the direction (`arrow.up` / `arrow.down` / `minus`).
        let symbol: String
        /// Sentiment colour — signal-only, neutral for `neutral`/target-band.
        let tint: Color
        /// Raw signed percentage (for tests + accessibility).
        let percent: Double
        /// Sentiment classification (for tests).
        let sentiment: Sentiment

        nonisolated static func == (lhs: Result, rhs: Result) -> Bool {
            lhs.deltaText == rhs.deltaText
                && lhs.symbol == rhs.symbol
                && lhs.percent == rhs.percent
                && lhs.sentiment == rhs.sentiment
        }
    }

    nonisolated enum Sentiment: Equatable {
        case favourable
        case adverse
        case neutral
    }

    /// Computes the period-over-period delta from the loaded series. Returns
    /// `nil` (→ the view self-suppresses) when there is no coherent prior window:
    /// fewer than two points overall, an empty current or prior half, or a
    /// prior mean of zero (no meaningful percentage).
    ///
    /// The window is split at the temporal midpoint of the loaded span: points
    /// before the midpoint form the *prior* half, points at/after it the
    /// *current* half. The delta percentage is `(meanCurrent − meanPrior) /
    /// |meanPrior| · 100`, rounded to one fractional digit and trimmed to whole
    /// numbers when integral.
    nonisolated static func resolve(
        points: [SeriesPoint],
        polarity: MetricKindDescriptor.TrendPolarity
    ) -> Result? {
        let sorted = points.sorted { $0.at < $1.at }
        guard sorted.count >= 4,
              let first = sorted.first?.at,
              let last = sorted.last?.at,
              first < last else { return nil }

        // Temporal midpoint of the loaded span.
        let midpoint = first.addingTimeInterval(last.timeIntervalSince(first) / 2)
        let prior = sorted.filter { $0.at < midpoint }
        let current = sorted.filter { $0.at >= midpoint }
        guard prior.count >= 2, current.count >= 2 else { return nil }

        let meanPrior = prior.map(\.value).reduce(0, +) / Double(prior.count)
        let meanCurrent = current.map(\.value).reduce(0, +) / Double(current.count)
        guard meanPrior != 0 else { return nil }

        let percent = (meanCurrent - meanPrior) / abs(meanPrior) * 100
        let rounded = (percent * 10).rounded() / 10

        let sentiment = sentiment(percent: rounded, polarity: polarity)
        return Result(
            deltaText: format(percent: rounded),
            symbol: symbol(for: rounded),
            tint: tint(for: sentiment),
            percent: rounded,
            sentiment: sentiment
        )
    }

    /// Sentiment from the signed percentage + polarity (mirrors web). A flat
    /// delta (≈0%) is always neutral.
    nonisolated static func sentiment(
        percent: Double,
        polarity: MetricKindDescriptor.TrendPolarity
    ) -> Sentiment {
        guard abs(percent) >= 0.05 else { return .neutral }
        switch polarity {
        case .neutral:
            return .neutral
        case .higherIsBetter:
            return percent > 0 ? .favourable : .adverse
        case .lowerIsBetter:
            return percent < 0 ? .favourable : .adverse
        }
    }

    nonisolated static func format(percent: Double) -> String {
        if abs(percent) < 0.05 {
            return String(localized: "insights.metric.rangeDelta.flat")
        }
        let sign = percent > 0 ? "+" : "−"
        let magnitude = abs(percent)
        let number = magnitude.formatted(.number.precision(.fractionLength(0 ... 1)))
        return "\(sign)\(number)\u{202F}%"
    }

    nonisolated static func symbol(for percent: Double) -> String {
        if abs(percent) < 0.05 { return "minus" }
        return percent > 0 ? "arrow.up" : "arrow.down"
    }

    nonisolated static func tint(for sentiment: Sentiment) -> Color {
        switch sentiment {
        // Monochrome doctrine: only the adverse signal carries colour, matching
        // the canonical `HLTileTrendGlyph` (`isAdverse → statusBad`). Favourable
        // + neutral stay mono so the metric column never alternates green/red.
        case .adverse: HLColor.statusBad
        case .favourable, .neutral: HLText.secondary
        }
    }
}
