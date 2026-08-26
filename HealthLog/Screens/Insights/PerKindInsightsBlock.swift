import SwiftUI

/// Insights coverage block — emits one observational card per `MetricKind`
/// for which the operator has at least N=5 measurements in the last 30 days.
///
/// **Why this exists (v0.5.4 BF-6):** the Insights mother-page previously
/// only surfaced cards for `bloodPressure` (BPStatusCard) and `weight`
/// (BMICard). Operator real-device walkthrough on v0.5.3 noted: "server
/// has Schritte, Puls, HRV, Glucose, Schlaf and the Insights screen still
/// shows nothing under the BP/BMI cards." The screen leaves all the other
/// kinds invisible even when data is sitting in the local store.
///
/// This block iterates every `MetricKind` and renders a per-kind insight
/// card whenever the 30-day-window slice has enough samples to derive a
/// meaningful summary. The card carries:
/// - sample count + 30d mean (numeric)
/// - latest value with direction-vs-mean arrow
/// - source-priority badge (HK / manual / mixed) so the operator knows
///   where the data is coming from
///
/// The block is purely deterministic — no AI inference fires. The
/// `TrendObservationCard` (on-device AI) still ships below BP and BMI;
/// this card is the *coverage floor* that guarantees every populated
/// kind has at least an observational surface on Insights.
public struct PerKindInsightsBlock: View {
    public let measurements: [Measurement]
    public let locale: Locale
    public let now: Date
    /// Per-call extra-exclusion set. v0.6.1.1 wave Y3 introduced the
    /// `InsightsTargetTileGrid` above this block — the kinds it already
    /// covers (Gewicht, Ruhepuls, Steps, Mood) should not show up a
    /// second time in the "Weitere Werte" long-tail. Defaults to empty
    /// so existing callers continue to fall through `excludedKinds`
    /// only.
    public let additionalExcludedKinds: Set<MetricKind>
    /// v0.10.0 W-Insights (R2 Phase D, drift D-013/D-014 close) — the long-tail
    /// now renders through the unified `HLMetricTile` (was a third tile
    /// anatomy). When the assistant is configured, every long-tail tile also
    /// offers the `✦` AI explainer; tapping it fires this closure.
    public let aiConfigured: Bool
    public let onAIExplainer: ((MetricKind) -> Void)?

    /// v0.10.0 — needed so each long-tail tile can push `ChartDetailScreen`
    /// (universal tap→chart). nil (Preview) → plain non-tappable tile.
    @Environment(\.appContainer) private var appContainer

    /// AUD-2 C2 — the 30-day group-by-kind + per-bucket stats + sort is
    /// memoized here instead of recomputed inside `var body`. The parent
    /// `InsightsScreen` subscribes to `measurementsStore`, so every SWR
    /// revalidation / network response re-invalidated this view's body and
    /// (pre-fix) re-ran the full multi-hundred-element walk + sort from
    /// scratch — the 200-500ms pull-to-refresh "freeze". The pure
    /// `qualifyingBuckets` function now fires only when its inputs actually
    /// change (`onChange(of: measurements)` / first `task`), and `body`
    /// just reads this cached slice.
    @State private var cachedBuckets: [PerKindInsightBucket] = []

    /// Kinds we *never* surface even when data is present. BP and Weight
    /// have their own dedicated cards (BPStatusCard / BMICard) above —
    /// rendering a duplicate per-kind card would be visually redundant.
    public nonisolated static let excludedKinds: Set<MetricKind> = [
        .bloodPressure,
        .weight
    ]

    /// Minimum number of measurements in the 30-day window for a kind
    /// to qualify for a card. Set deliberately low (5) so power-users
    /// see coverage even for kinds they only sample weekly.
    public nonisolated static let minimumSampleCount = 5

    public init(
        measurements: [Measurement],
        excludedKinds: Set<MetricKind> = [],
        locale: Locale = .current,
        now: Date = .now,
        aiConfigured: Bool = false,
        onAIExplainer: ((MetricKind) -> Void)? = nil
    ) {
        self.measurements = measurements
        additionalExcludedKinds = excludedKinds
        self.locale = locale
        self.now = now
        self.aiConfigured = aiConfigured
        self.onAIExplainer = onAIExplainer
    }

    public var body: some View {
        // AUD-2 C2 — `body` reads the memoized `cachedBuckets` instead of
        // recomputing the 30-day group-by-kind + per-bucket stats + sort on
        // every invalidation. The slice is (re)derived only when its inputs
        // change (`task` + `onChange(of: measurements)`).
        Group {
            if !cachedBuckets.isEmpty {
                VStack(alignment: .leading, spacing: HLSpace.md) {
                    InsightsSectionHeader("More values")
                    // v0.10.0 W-Insights (R2 Phase D / drift D-013/D-014) — the
                    // long-tail renders through the unified `HLMetricTile` so the
                    // whole grid reads as ONE anatomy, each tile tap→chart + `✦`.
                    ForEach(cachedBuckets, id: \.kind) { bucket in
                        longTailTile(for: bucket)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task(id: bucketCacheKey) { recomputeBuckets() }
    }

    /// Lightweight identity key over the inputs of `qualifyingBuckets`.
    /// Changing measurements (count / endpoints / latest stamp), the
    /// per-call exclusion set, or `now` re-derives the cache; an unrelated
    /// store mutation that re-invalidates the body does not. Avoids an
    /// O(n) full-array `Equatable` compare on every render.
    private var bucketCacheKey: BucketCacheKey {
        BucketCacheKey(
            count: measurements.count,
            firstID: measurements.first?.id,
            lastID: measurements.last?.id,
            lastRecordedAt: measurements.last?.recordedAt,
            // BH-final-diff M3 — fingerprint the full content so an IN-PLACE edit
            // (same id, same recordedAt — value / note / source changed) still
            // invalidates. The endpoint-id + count + lastRecordedAt key missed
            // these byte-identically, so the mean / latest could render stale.
            contentHash: Self.contentHash(of: measurements),
            excluded: additionalExcludedKinds,
            now: now
        )
    }

    /// Order-sensitive content hash over every measurement (id + value + note +
    /// source + recordedAt via `Measurement: Hashable`). O(n) but cheap, and it
    /// is the only signal that catches an in-place edit (BH-final-diff M3).
    private static func contentHash(of measurements: [Measurement]) -> Int {
        var hasher = Hasher()
        for measurement in measurements {
            hasher.combine(measurement)
        }
        return hasher.finalize()
    }

    private func recomputeBuckets() {
        cachedBuckets = Self.qualifyingBuckets(
            measurements: measurements,
            additionalExcluded: additionalExcludedKinds,
            now: now
        )
    }

    @ViewBuilder
    private func longTailTile(for bucket: PerKindInsightBucket) -> some View {
        let tile = HLMetricTile(
            icon: bucket.kind.descriptor.sfSymbol,
            titleResource: bucket.kind.descriptor.title,
            value: Self.valueText(for: bucket, locale: locale),
            unit: bucket.kind.unit.isEmpty ? nil : bucket.kind.unit,
            trend: Self.trend(for: bucket),
            sparkline: Self.sparkline(for: bucket),
            context: Self.contextLine(for: bucket, locale: locale),
            onAIExplainer: aiHandler(for: bucket.kind),
            // Task #36 — the long-tail tile carries its `MetricKind`, so its
            // sparkline mirrors the metric's Insights chart vocabulary (same
            // engine + `inkGraphite` ink) rather than a generic grey line.
            chartKind: bucket.kind
        )
        if let container = appContainer {
            NavigationLink {
                // W36/#22 — chart-detail cutover: long-tail metric tiles drill
                // into the web-mirror per-metric screen (bottom-period control),
                // matching every other Insights chart surface.
                InsightsMetricScreen(
                    kind: bucket.kind,
                    store: container.makeChartDetailStore(kind: bucket.kind)
                )
            } label: {
                tile
            }
            .hlPressable() // QOL-AUDIT H1: press feedback
            .accessibilityIdentifier("insights.tile.\(bucket.kind.rawValue)")
            .accessibilityHint(Text(String(localized: "Double-tap to open detail view")))
            // v0.14 A — long-press to pin/unpin this metric to the home dashboard.
            .pinToHomeContextMenu(kind: bucket.kind, container: container)
        } else {
            tile
                .accessibilityIdentifier("insights.tile.\(bucket.kind.rawValue)")
                .pinToHomeContextMenu(kind: bucket.kind, container: appContainer)
        }
    }

    private func aiHandler(for kind: MetricKind) -> (() -> Void)? {
        guard aiConfigured, let onAIExplainer else { return nil }
        return { onAIExplainer(kind) }
    }

    /// Compute the qualifying buckets — pure-function so tests can lock
    /// the contract without instantiating the view.
    public nonisolated static func qualifyingBuckets(
        measurements: [Measurement],
        additionalExcluded: Set<MetricKind> = [],
        now: Date = .now
    ) -> [PerKindInsightBucket] {
        let cutoff = now.addingTimeInterval(-30 * 86400)
        var byKind: [MetricKind: [Measurement]] = [:]
        for m in measurements where m.recordedAt >= cutoff {
            byKind[m.kind, default: []].append(m)
        }
        return byKind.compactMap { kind, rows -> PerKindInsightBucket? in
            guard !excludedKinds.contains(kind) else { return nil }
            guard !additionalExcluded.contains(kind) else { return nil }
            guard rows.count >= minimumSampleCount else { return nil }
            return PerKindInsightBucket(kind: kind, rows: rows, now: now)
        }
        .sorted { lhs, rhs in
            // Order by sample count descending so the most-active kinds
            // surface first; tie-break alphabetically on display name
            // for stability across renders.
            if lhs.samples != rhs.samples {
                return lhs.samples > rhs.samples
            }
            return lhs.kind.displayName < rhs.kind.displayName
        }
    }
}

/// AUD-2 C2 — identity key for memoizing `PerKindInsightsBlock`'s bucket
/// derivation. `Equatable` so `.task(id:)` only re-fires when a field
/// actually changes (cheaper than comparing the whole `[Measurement]`).
private struct BucketCacheKey: Equatable {
    let count: Int
    let firstID: String?
    let lastID: String?
    let lastRecordedAt: Date?
    /// Content fingerprint catching in-place value/note/source edits that leave
    /// id + recordedAt unchanged (BH-final-diff M3).
    let contentHash: Int
    let excluded: Set<MetricKind>
    let now: Date
}

/// Deterministic per-kind bucket — sample count, 30d mean, latest value,
/// source breakdown. The view consumes pre-computed numbers so the body
/// stays cheap.
public struct PerKindInsightBucket: Sendable, Equatable {
    public let kind: MetricKind
    public let samples: Int
    public let mean: Double?
    public let latest: Measurement?
    /// `nil` for BP (handled via dedicated card); otherwise +x/-x/=
    /// representing latest vs mean direction.
    public let directionArrow: String?
    /// True iff measurements split across multiple sources (HK + manual).
    public let mixedSources: Bool
    /// Most-common source — used for the badge label.
    public let dominantSource: MeasurementSource
    /// v0.10.0 W-Insights — time-ordered primary-value series for the unified
    /// `HLMetricTile` sparkline (oldest→newest). ≥2 points to render a line.
    public let sparkline: [Double]

    public init(kind: MetricKind, rows: [Measurement], now _: Date = .now) {
        self.kind = kind
        samples = rows.count
        let scalars = rows.map(\.primaryValue)
        mean = scalars.isEmpty ? nil : scalars.reduce(0, +) / Double(scalars.count)
        latest = rows.max(by: { $0.recordedAt < $1.recordedAt })
        sparkline = rows
            .sorted { $0.recordedAt < $1.recordedAt }
            .map(\.primaryValue)

        // Source dominance: count rows per source, dominant = max-count.
        var sourceCounts: [MeasurementSource: Int] = [:]
        for r in rows {
            sourceCounts[r.source, default: 0] += 1
        }
        mixedSources = sourceCounts.count > 1
        dominantSource = sourceCounts.max { $0.value < $1.value }?.key ?? .manual

        // Direction arrow — same convention as StatistikMode (+5% threshold).
        if kind == .bloodPressure {
            directionArrow = nil
        } else if let latest, let mean, samples > 1 {
            let latestScalar = latest.primaryValue
            let threshold = max(0.001, mean * 0.05)
            if latestScalar > mean + threshold {
                directionArrow = "↑"
            } else if latestScalar < mean - threshold {
                directionArrow = "↓"
            } else {
                directionArrow = "→"
            }
        } else {
            directionArrow = nil
        }
    }
}

// MARK: - Long-tail tile formatting (v0.10.0 W-Insights, R2 Phase D)

extension PerKindInsightsBlock {
    /// Latest value formatted for the unified tile's value row.
    nonisolated static func valueText(for bucket: PerKindInsightBucket, locale _: Locale) -> String {
        guard let latest = bucket.latest else { return "\u{2014}" }
        switch latest.value {
        case let .scalar(v):
            return formatScalar(v, kind: bucket.kind, includeUnit: false)
        case let .bloodPressure(s, d):
            return String(format: "%.0f/%.0f", s, d)
        }
    }

    /// The quiet context line: source + sample count + 30-day average (the
    /// "deep" line). Mirrors the operator's "X measurements / Ø 30d" read the
    /// old card carried, now in one caption.
    nonisolated static func contextLine(for bucket: PerKindInsightBucket, locale _: Locale) -> String {
        let samplesPart = String(localized: "\(bucket.samples) measurements · last 30 days")
        guard let mean = bucket.mean, bucket.kind != .bloodPressure else { return samplesPart }
        let meanText = formatScalar(mean, kind: bucket.kind, includeUnit: true)
        let avgPart = String(localized: "30-day avg \(meanText)")
        return "\(samplesPart) · \(avgPart)"
    }

    /// Latest-vs-mean direction → polarity-agnostic `HLMetricTile.Trend`. The
    /// long-tail has no per-kind target polarity, so we only mark "stable" vs
    /// "changed" (favourable, mono) — never adverse-red (no red on a metric we
    /// can't judge as good/bad).
    nonisolated static func trend(for bucket: PerKindInsightBucket) -> HLMetricTile.Trend {
        switch bucket.directionArrow {
        case "\u{2191}", "\u{2193}": .favorable
        case "\u{2192}": .stable
        default: .none
        }
    }

    /// The unified-tile sparkline (≥2 points to render a line).
    nonisolated static func sparkline(for bucket: PerKindInsightBucket) -> [Double] {
        bucket.sparkline
    }

    private nonisolated static func formatScalar(_ value: Double, kind: MetricKind, includeUnit: Bool) -> String {
        let formatted = switch kind {
        case .pulse, .restingHeartRate, .spo2, .glucose, .steps:
            String(format: "%.0f", value)
        default:
            HLNumberFormat.decimal(value, fractionDigits: 1)
        }
        let unit = kind.unit
        return (includeUnit && !unit.isEmpty) ? "\(formatted) \(unit)" : formatted
    }
}
