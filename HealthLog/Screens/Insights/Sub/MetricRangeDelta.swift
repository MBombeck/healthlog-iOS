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
/// **1.5 VERDICTS (#135 rest) — the server's change first.** Since v1.43 the
/// series carries `change`: the first and the last day value of the window and
/// how that change counts (`sentiment`). When it is there the caption shows
/// that delta in the metric's unit and says what it compares ("since the first
/// day in range"), coloured by the server's verdict: adverse red, favourable
/// green, the rest neutral. A server that knows `change` but sent none (under
/// two days) gets no caption. Only a server before v1.43 still gets the
/// in-window split described above, always neutral: the app does not judge a
/// change itself, and the old per-metric polarity table is gone.
///
/// **Self-suppression (calm doctrine):** with no prior-window data — fewer than
/// two points in either half, or a zero/▏undefined prior mean — the view renders
/// **nothing** (no "—", no apologetic empty caption). A sparse metric simply
/// shows the range control with no delta line.
struct MetricRangeDelta: View {
    /// Where the figure comes from.
    enum Source {
        /// The server's `change`, already in the account's unit.
        case server(delta: Double, unit: String, sentiment: TrendSentiment)
        /// A server before v1.43: the chart's loaded points for the selected
        /// range (chronological or not, the resolver sorts by date).
        case ownComparison([SeriesPoint])
    }

    let source: Source
    /// The selected range, supplying the "vs prior <label>" suffix of the own
    /// comparison.
    let range: ChartDetailStore.Range
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if let result = Self.resolve(source) {
            // POLISH-B (SHOTS F-AX-DELTA) — one line up to XXXL; from the
            // accessibility sizes on the comparison stands under the figure
            // and wraps instead of reading "ggü. Vo…".
            let wraps = dynamicTypeSize.isAccessibilitySize
            let layout = wraps
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: HLSpace.xxs))
                : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: HLSpace.xxs))
            layout {
                HStack(alignment: .firstTextBaseline, spacing: HLSpace.xxs) {
                    Image(systemName: result.symbol)
                        .accessibilityHidden(true)
                    Text(result.deltaText)
                        .monospacedDigit()
                }
                Text(suffix(result))
                    .fixedSize(horizontal: false, vertical: wraps)
            }
            .font(.hlCaption)
            .foregroundStyle(result.tint)
            .lineLimit(wraps ? nil : 1)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(Self.accessibilityText(result, priorLabel: suffix(result))))
            .accessibilityIdentifier("insights.metric.rangeDelta")
        }
    }

    /// What the figure compares: the server's first-to-last-day change, or the
    /// prior window of the own comparison.
    private func suffix(_ result: Result) -> String {
        Self.suffix(for: result, range: range)
    }

    nonisolated static func suffix(for result: Result, range: ChartDetailStore.Range, bundle: Bundle = .main) -> String {
        result.percent == nil
            ? String(localized: "insights.metric.rangeDelta.sinceFirstDay", bundle: bundle)
            : priorLabel(for: range, bundle: bundle)
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

    /// #135 — VoiceOver hears the verdict the tint shows ("a good direction
    /// for you"), not only the number. Neutral adds nothing.
    nonisolated static func accessibilityText(_ result: Result, priorLabel: String) -> String {
        let spoken: TrendSentiment = switch result.sentiment {
        case .favourable: .positive
        case .adverse: .negative
        case .neutral: .neutral
        }
        let base = "\(result.deltaText) \(priorLabel)"
        guard let clause = spoken.spokenClause else { return base }
        return "\(base), \(clause)"
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
        /// Raw signed percentage of the own comparison; `nil` for the
        /// server's change (shown in the metric's unit, not as a percentage).
        let percent: Double?
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

    nonisolated static func resolve(_ source: Source) -> Result? {
        switch source {
        case let .server(delta, unit, sentiment):
            resolve(serverDelta: delta, unit: unit, sentiment: sentiment)
        case let .ownComparison(points):
            resolve(points: points)
        }
    }

    /// The server's change as sent: signed, in the metric's unit, coloured by
    /// the server's verdict. `nil` for a figure that is not finite.
    nonisolated static func resolve(serverDelta delta: Double, unit: String, sentiment verdict: TrendSentiment) -> Result? {
        guard delta.isFinite else { return nil }
        let rounded = (delta * 10).rounded() / 10
        let magnitude = abs(rounded).formatted(.number.precision(.fractionLength(0 ... 1)))
        let number = rounded == 0 ? "±" + magnitude : (rounded > 0 ? "+" : "−") + magnitude
        let sentiment: Sentiment = switch verdict {
        case .positive: .favourable
        case .negative: .adverse
        case .neutral, .unknown: .neutral
        }
        return Result(
            deltaText: unit.isEmpty ? number : "\(number) \(unit)",
            symbol: rounded == 0 ? "minus" : (rounded > 0 ? "arrow.up" : "arrow.down"),
            tint: tint(for: sentiment),
            percent: nil,
            sentiment: sentiment
        )
    }

    /// The own comparison for a server before v1.43, always neutral. Returns
    /// `nil` (→ the view self-suppresses) when there is no coherent prior
    /// window: fewer than two points in either half, or a prior mean of zero.
    ///
    /// The window is split at the temporal midpoint of the loaded span: points
    /// before the midpoint form the *prior* half, points at/after it the
    /// *current* half. The delta percentage is `(meanCurrent − meanPrior) /
    /// |meanPrior| · 100`, rounded to one fractional digit and trimmed to whole
    /// numbers when integral.
    nonisolated static func resolve(points: [SeriesPoint]) -> Result? {
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
        return Result(
            deltaText: format(percent: rounded),
            symbol: symbol(for: rounded),
            tint: tint(for: .neutral),
            percent: rounded,
            sentiment: .neutral
        )
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
        // 1.5 VERDICTS — the same colours as the hero chip and the tiles: the
        // server's verdict paints, nothing else does.
        switch sentiment {
        case .adverse: HLColor.statusBad
        case .favourable: HLColor.statusOK
        case .neutral: HLText.secondary
        }
    }
}
