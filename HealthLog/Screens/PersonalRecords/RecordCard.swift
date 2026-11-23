import Charts
import SwiftUI

/// Grid tile rendering one `PersonalRecord`.
///
/// 2-col `LazyVGrid` cell, ~168pt tall, `.elevated`. Anatomy (top-down):
/// - 18pt kind glyph + caption (`metricSlot` or metric label, uppercased).
/// - Value + unit in the tile size (`HLValueText(.tile)`).
/// - Mini sparkline (~32pt) with a filled `Circle()` overlay at the
///   peak index (and a tiny star above as a peak-flag indicator).
/// - Footer row: relative timestamp + delta chip ("Neuer Rekord!" /
///   "+12% vs. previous", catalog `records.delta.vsPrevious`).
///
/// **Tap target:** the entire card opens the record's metric page, where the
/// record is a point in the history. Sharing sits in the context menu. A
/// record without a metric page (no resolvable kind) keeps sharing on tap;
/// `onTap` is the share callback either way.
///
/// **Accessibility:** the whole card collapses to a single
/// VoiceOver element with a synthesised summary so users don't have
/// to swipe through each label individually.
struct RecordCard: View {
    /// The account's display units.
    @Environment(\.unitPreferences) private var unitPreferences
    let record: PersonalRecord
    let onTap: (PersonalRecord) -> Void

    /// What a tap on the card does.
    enum TapAction: Equatable {
        /// Push the metric page of this kind.
        case openMetric(MetricKind)
        /// Share the record (no metric page to open).
        case share
    }

    /// The metric page when the record names a kind the app can show,
    /// otherwise sharing, as before.
    nonisolated static func tapAction(for record: PersonalRecord) -> TapAction {
        guard let kind = record.kind, kind != .unknown else { return .share }
        return .openMetric(kind)
    }

    var body: some View {
        Group {
            switch Self.tapAction(for: record) {
            case let .openMetric(kind):
                NavigationLink {
                    RecordMetricDestination(kind: kind)
                } label: {
                    card
                }
                .buttonStyle(.hlRow)
            case .share:
                Button {
                    onTap(record)
                } label: {
                    card
                }
                .buttonStyle(.hlRow)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint)
        .accessibilityAction(named: Text("Share record")) { onTap(record) }
        .contextMenu {
            Button {
                onTap(record)
            } label: {
                Label("Share record", systemImage: "square.and.arrow.up")
            }
        }
    }

    private var card: some View {
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                header
                valueRow
                sparklineRow
                footer
            }
            // Fills the row's height, so the cards of a row end together.
            .frame(maxWidth: .infinity, minHeight: 168, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var accessibilityHint: Text {
        switch Self.tapAction(for: record) {
        case .openMetric: Text("records.card.a11y.opensMetric")
        case .share: Text("Tap to share this record.")
        }
    }

    // MARK: - Subviews

    private var header: some View {
        HStack(spacing: HLSpace.xs) {
            Image(systemName: glyphName)
                .font(.hlIcon(HLIconSize.lg))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            // The label wraps a long metric name ("Herzfrequenzvariabilität")
            // itself instead of cutting it.
            HLCardLabel(verbatim: metricLabel)
        }
    }

    /// The record in the account's unit, one decimal at most like before.
    private var valueRow: some View {
        HLValueText(
            record.base.displayValue(unitPreferences),
            unit: HLUnit(symbol: unitLabel),
            size: .tile,
            fractionDigits: 0 ... 1
        )
        // A five-digit step count with its unit is wider than a half-width
        // card; it shrinks to fit instead of ending in "…".
        .minimumScaleFactor(0.6)
    }

    @ViewBuilder
    private var sparklineRow: some View {
        if record.sparklineValues.count >= 2 {
            sparklineChart
                .frame(height: HLChartStyle.heightCompact)
        } else {
            // Reserve the slot so cards in the same row stay equal height.
            Color.clear.frame(height: HLChartStyle.heightCompact)
        }
    }

    private var sparklineChart: some View {
        Chart {
            ForEach(Array(record.sparklineValues.enumerated()), id: \.offset) { idx, value in
                LineMark(
                    x: .value("Index", idx),
                    y: .value("Value", value)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(tint)
                .lineStyle(StrokeStyle(lineWidth: HLChartStyle.lineWidth, lineCap: .round, lineJoin: .round))
                if idx == (record.peakIndex ?? -1) {
                    PointMark(
                        x: .value("Index", idx),
                        y: .value("Value", value)
                    )
                    .symbol(.circle)
                    .symbolSize(60)
                    .foregroundStyle(tint)
                }
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: yDomain)
        .accessibilityHidden(true)
    }

    /// POLISH-B (SHOTS F-REC-1) — the time over the chip, both whole. Side by
    /// side in a half-width card they read "vor 2 Mona…" and "Neuer Rekord
    /// !" even at the default size.
    private var footer: some View {
        VStack(alignment: .leading, spacing: HLSpace.xs) {
            Text(relativeDateLabel)
                .font(.hlCaption)
                .foregroundStyle(HLText.secondary)
                .fixedSize(horizontal: false, vertical: true)
            deltaChip
        }
    }

    @ViewBuilder
    private var deltaChip: some View {
        if let delta = record.delta {
            // Trend arrows point straight up or down; the diagonal is the
            // sign for a link that leaves the app. No change has no arrow
            // and no colour: "+0 %" in green read like a gain.
            let style = Self.deltaStyle(delta: delta)
            HLBadge(Self.deltaLabel(delta: delta), icon: style.symbol, tone: style.tone)
        } else {
            // `HLBadge` takes a display string; the literal was
            // never looked up, so German read "New record!".
            HLBadge(String(localized: "New record!"), icon: "sparkles", tone: .neutral)
        }
    }

    // MARK: - Derived

    private var tint: Color {
        PersonalRecordKindTint.color(for: record.kind)
    }

    private var glyphName: String {
        guard let kind = record.kind else { return "rosette" }
        return MetricKindDescriptor.descriptor(for: kind).sfSymbol
    }

    private var metricLabel: String {
        if let slot = record.base.metricSlot, !slot.isEmpty {
            return slot
        }
        return MetricTypeLocalisation.label(forType: record.base.metricType)
    }

    /// The record in the account's unit (the row is canonical).
    private var formattedValue: String {
        let value = record.base.displayValue(unitPreferences)
        return Self.numberFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private var unitLabel: String {
        record.base.displayUnit(unitPreferences)
    }

    private var relativeDateLabel: String {
        // Native Date.RelativeFormatStyle replaces the de_DE-hardcoded
        // RelativeDateTimeFormatter — the footer timestamp now renders per
        // device locale. `.named` + `.abbreviated` mirror the prior natural
        // "vor 5 Tagen"/"5 days ago" abbreviated phrasing.
        record.base.achievedAt.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    }

    /// Arrow and tone of the change chip: up and green for a gain, down and
    /// amber for a loss, neither for a change that rounds to nothing.
    static func deltaStyle(delta: PersonalRecord.Delta) -> (symbol: String?, tone: HLBadge.Tone) {
        let shown = delta.percent.map { ($0 * 100).rounded() } ?? delta.absolute
        if shown == 0 { return (nil, .neutral) }
        return shown > 0 ? ("arrow.up", .success) : ("arrow.down", .warning)
    }

    static func deltaLabel(delta: PersonalRecord.Delta) -> String {
        // A step under half a percent read "+0 % vs. zuvor" on a new best,
        // which says nothing; it shows its absolute size instead.
        if let percent = delta.percent, abs(percent * 100).rounded() >= 1 {
            let signed = percent * 100
            let prefix = signed >= 0 ? "+" : ""
            let percentText = prefix + HLNumberFormat.percent(Int(signed.rounded()))
            return String(localized: "records.delta.vsPrevious \(percentText)")
        }
        let signed = delta.absolute
        let prefix = signed >= 0 ? "+" : ""
        return "\(prefix)\(Self.numberFormatter.string(from: NSNumber(value: signed)) ?? "")"
    }

    private var yDomain: ClosedRange<Double> {
        guard let lo = record.sparklineValues.min(), let hi = record.sparklineValues.max() else {
            return 0 ... 1
        }
        guard hi > lo else { return lo - 0.5 ... lo + 0.5 }
        let pad = (hi - lo) * 0.1
        return (lo - pad) ... (hi + pad)
    }

    private var accessibilityLabel: Text {
        let metric = metricLabel
        let value = "\(formattedValue) \(unitLabel)"
        let date = HLDateFormat.date(record.base.achievedAt, style: .abbreviated)
        let deltaText: String = {
            guard let delta = record.delta else { return String(localized: "records.a11y.newRecord") }
            return String(localized: "records.a11y.change \(Self.deltaLabel(delta: delta))")
        }()
        return Text("\(metric): \(value), reached on \(date). \(deltaText)")
    }

    private static let numberFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Locale.current
        f.numberStyle = .decimal
        f.maximumFractionDigits = 1
        f.minimumFractionDigits = 0
        return f
    }()
}

/// The metric page a record card opens, built only when pushed. Pushed
/// outside the Insights pager, it needs the bar for the way back and has no
/// strip of its own.
private struct RecordMetricDestination: View {
    let kind: MetricKind

    @Environment(\.appContainer) private var appContainer

    var body: some View {
        if let appContainer {
            InsightsMetricScreen(kind: kind, store: appContainer.makeChartDetailStore(kind: kind))
                .toolbar(.visible, for: .navigationBar)
                .environment(\.insightsInPager, false)
        }
    }
}

#Preview("RecordCard — grid") {
    let dto = PersonalRecordDTO(
        id: "preview.weight",
        userId: "u1",
        metricType: "WEIGHT",
        metricSlot: nil,
        direction: .min,
        value: 78.2,
        unit: "kg",
        achievedAt: Date().addingTimeInterval(-86400 * 5),
        sourceMeasurementId: nil,
        source: "MANUAL",
        externalId: nil,
        createdAt: Date()
    )
    let record = PersonalRecord(
        id: dto.id,
        base: dto,
        kind: .weight,
        sparklineValues: [82, 81.5, 81.4, 81.2, 80.8, 80.6, 80.5, 80.1, 79.7, 79.2, 78.8, 78.5, 78.2],
        peakIndex: 12,
        previousValue: 79.7,
        bucket: .month,
        impressiveness: 0.7
    )
    return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: HLSpace.md) {
        RecordCard(record: record, onTap: { _ in })
        RecordCard(record: record, onTap: { _ in })
    }
    .padding()
    .background(HLSurface.primary)
}
