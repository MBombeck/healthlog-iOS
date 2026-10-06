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
/// **Sentiment — the server's, or none (#115 · 1.3).** The caption used to
/// decide good or bad itself from a hard-coded per-metric polarity table
/// (weight "lower is better" for everyone, pulse "lower is better", …). That is
/// a clinical judgement the app does not own. The only verdict the server
/// publishes today is the weight one (`tiles.weightTrend.direction`, judged
/// against the person's own target); the weight page passes it, every other
/// metric passes `nil` and the caption stays neutral — direction and size are
/// shown, never tinted as good or bad. Colour stays signal-only (STANDARDS §7):
/// only an ADVERSE server verdict carries `HLColor.statusBad`.
///
/// **Self-suppression (calm doctrine):** with no prior-window data — fewer than
/// two points in either half, or a zero/▏undefined prior mean — the view renders
/// **nothing** (no "—", no apologetic empty caption). A sparse metric simply
/// shows the range control with no delta line.
struct MetricRangeDelta: View {
    /// The chart's loaded points for the selected range (chronological or not —
    /// the resolver sorts by date internally).
    let points: [SeriesPoint]
    /// The server's verdict on which way is progress (weight only, from the
    /// dashboard snapshot). `nil` → neutral: no good/bad colouring.
    let sentiment: TrendDirectionSentiment?
    /// The selected range, supplying the "vs prior <label>" suffix.
    let range: ChartDetailStore.Range

    var body: some View {
        if let result = Self.resolve(points: points, sentiment: sentiment) {
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
        Self.priorLabel(for: range)
    }

    /// One catalog phrase per range (H2, 1.1.0). The suffix used to lowercase
    /// the range's display name into a shared template, which German cannot
    /// do: nouns keep their capital, and "ggü. Monat davor" is not how the
    /// language says it — "ggü. Vormonat" is.
    nonisolated static func priorLabel(for range: ChartDetailStore.Range, bundle: Bundle = .main) -> String {
        switch range {
        case .day: String(localized: "insights.metric.rangeDelta.prior.day", bundle: bundle)
        case .week: String(localized: "insights.metric.rangeDelta.prior.week", bundle: bundle)
        case .month: String(localized: "insights.metric.rangeDelta.prior.month", bundle: bundle)
        case .sixMonths: String(localized: "insights.metric.rangeDelta.prior.sixMonths", bundle: bundle)
        case .year: String(localized: "insights.metric.rangeDelta.prior.year", bundle: bundle)
        case .all: String(localized: "insights.metric.rangeDelta.prior.all", bundle: bundle)
        }
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
        sentiment serverSentiment: TrendDirectionSentiment?
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

        let sentiment = sentiment(percent: rounded, server: serverSentiment)
        return Result(
            deltaText: format(percent: rounded),
            symbol: symbol(for: rounded),
            tint: tint(for: sentiment),
            percent: rounded,
            sentiment: sentiment
        )
    }

    /// Sentiment from the signed percentage and the server's verdict. No
    /// verdict → neutral. A flat delta (≈0%) is a level change, which only a
    /// `hold` verdict reads as progress.
    nonisolated static func sentiment(
        percent: Double,
        server: TrendDirectionSentiment?
    ) -> Sentiment {
        guard let server else { return .neutral }
        let change: TrendDirectionSentiment.Change = if abs(percent) < 0.05 {
            .level
        } else {
            percent > 0 ? .rising : .falling
        }
        switch server.tone(for: change) {
        case .favorable: return .favourable
        case .adverse: return .adverse
        case .neutral: return .neutral
        }
    }

    nonisolated static func format(percent: Double) -> String {
        if abs(percent) < 0.05 {
            return String(localized: "insights.metric.rangeDelta.flat")
        }
        let sign = percent > 0 ? "+" : "−"
        let magnitude = abs(percent)
        let number = magnitude.formatted(.number.precision(.fractionLength(0 ... 1)))
        // F1 — the locale places the sign: "+4,2 %" in German, "+4.2%" in English.
        return sign + HLNumberFormat.percent(formattedNumber: number)
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
