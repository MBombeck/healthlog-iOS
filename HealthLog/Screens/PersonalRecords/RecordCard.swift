import Charts
import SwiftUI

/// v0.5.5.6 POLISH-PR — grid tile rendering one `PersonalRecord`.
///
/// 2-col `LazyVGrid` cell, ~168pt tall, `.elevated`. Anatomy (top-down):
/// - 18pt kind glyph + caption (`metricSlot` or metric label, uppercased).
/// - 32pt-bold rounded value + unit row.
/// - Mini sparkline (~32pt) with a filled `Circle()` overlay at the
///   peak index (and a tiny star above as a peak-flag indicator).
/// - Footer row: relative timestamp + delta chip ("Neuer Rekord!" /
///   "+12% vs. zuvor").
///
/// **Tap target:** the entire card is a button — taps emit `onTap`
/// upstream so the screen can present a share sheet or push to
/// chart detail. The card itself does not own navigation.
///
/// **Accessibility:** the whole card collapses to a single
/// VoiceOver element with a synthesised summary so users don't have
/// to swipe through each label individually.
struct RecordCard: View {
    let record: PersonalRecord
    let onTap: (PersonalRecord) -> Void

    /// Audit-01 H3 — the record value keeps its 32pt visual weight at the
    /// default setting but now scales with Dynamic Type (accessibility text
    /// sizes were previously ignored by the pixel-locked `hlMetric(32)`).
    @ScaledMetric(relativeTo: .largeTitle) private var valueSize: CGFloat = 32

    var body: some View {
        Button {
            onTap(record)
        } label: {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                header
                valueRow
                sparklineRow
                footer
            }
            .padding(HLSpace.md)
            .frame(maxWidth: .infinity, minHeight: 168, alignment: .topLeading)
            .background(HLSurface.secondary, in: RoundedRectangle(cornerRadius: HLRadius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: HLRadius.card, style: .continuous)
                    .stroke(HLColor.separator, lineWidth: 0.5)
            }
            .hlShadow(HLShadow.cardLight)
        }
        .buttonStyle(HLPressableButtonStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(Text("Tap to share this record."))
    }

    // MARK: - Subviews

    private var header: some View {
        HStack(spacing: HLSpace.xs) {
            Image(systemName: glyphName)
                .font(.hlIcon(HLIconSize.lg))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            HLSectionLabel(verbatim: metricLabel)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    private var valueRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: HLSpace.xs) {
            Text(formattedValue)
                // Design-system metric token, Dynamic-Type-scaled via the
                // `valueSize` @ScaledMetric (audit-01 H3).
                .font(.hlMetric(valueSize))
                .foregroundStyle(HLText.primary)
                .monospacedDigit()
                .lineLimit(1)
                // v0.8.0 W6 — 0.6 → 0.75: record value stays legible at large
                // Dynamic Type instead of crushing below its caption.
                .minimumScaleFactor(0.75)
                .contentTransition(.numericText(value: record.base.value))
            if !record.base.unit.isEmpty {
                Text(record.base.unit)
                    // v0.11 reconcile (#12 sizing-drift): footnote token (13pt)
                    // instead of a raw system-size font.
                    .font(.hlFootnote.weight(.semibold))
                    .foregroundStyle(HLText.secondary)
            }
        }
    }

    @ViewBuilder
    private var sparklineRow: some View {
        if record.sparklineValues.count >= 2 {
            sparklineChart
                .frame(height: 32)
        } else {
            // Reserve the slot so cards in the same row stay equal height.
            Color.clear.frame(height: 32)
        }
    }

    private var sparklineChart: some View {
        Chart {
            ForEach(Array(record.sparklineValues.enumerated()), id: \.offset) { idx, value in
                LineMark(
                    x: .value("Index", idx),
                    y: .value("Wert", value)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(tint)
                .lineStyle(StrokeStyle(lineWidth: HLChartStyle.lineWidth, lineCap: .round, lineJoin: .round))
                if idx == (record.peakIndex ?? -1) {
                    PointMark(
                        x: .value("Index", idx),
                        y: .value("Wert", value)
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

    private var footer: some View {
        HStack(spacing: HLSpace.xs) {
            Text(relativeDateLabel)
                .font(.hlCaption)
                .foregroundStyle(HLText.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            deltaChip
        }
    }

    @ViewBuilder
    private var deltaChip: some View {
        if let delta = record.delta {
            let isImprovement = delta.absolute >= 0
            let symbol = isImprovement ? "arrow.up.right" : "arrow.down.right"
            let tone: HLBadge.Tone = isImprovement ? .success : .warning
            let label = Self.deltaLabel(delta: delta)
            HLBadge(label, icon: symbol, tone: tone)
        } else {
            HLBadge("New record!", icon: "sparkles", tone: .neutral)
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

    private var formattedValue: String {
        Self.numberFormatter.string(from: NSNumber(value: record.base.value)) ?? "\(record.base.value)"
    }

    private var relativeDateLabel: String {
        // Native Date.RelativeFormatStyle replaces the de_DE-hardcoded
        // RelativeDateTimeFormatter — the footer timestamp now renders per
        // device locale. `.named` + `.abbreviated` mirror the prior natural
        // "vor 5 Tagen"/"5 days ago" abbreviated phrasing.
        record.base.achievedAt.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    }

    static func deltaLabel(delta: PersonalRecord.Delta) -> String {
        if let percent = delta.percent {
            let signed = percent * 100
            let prefix = signed >= 0 ? "+" : ""
            return "\(prefix)\(Int(signed.rounded()))% vs. zuvor"
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
        let value = "\(formattedValue) \(record.base.unit)"
        let date = HLDateFormat.date(record.base.achievedAt, style: .abbreviated)
        let deltaText: String = {
            guard let delta = record.delta else { return "Neuer Rekord." }
            return "Veränderung: \(Self.deltaLabel(delta: delta))."
        }()
        return Text("\(metric): \(value), reached on \(date). \(deltaText)")
    }

    private static let numberFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.numberStyle = .decimal
        f.maximumFractionDigits = 1
        f.minimumFractionDigits = 0
        return f
    }()
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
