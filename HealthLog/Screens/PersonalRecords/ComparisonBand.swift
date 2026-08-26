import SwiftUI

/// v0.5.5.7 RECONCILE-COMPARE — clinical-benchmark comparison band
/// for the `PersonalRecordsScreen`.
///
/// Closes POLISH-PR component #5, which deferred in v0.5.5.6 because
/// no `ClinicalBenchmarkProvider` existed yet. The band paints a
/// per-record reference stripe (population mean ± 1σ) with the user's
/// best value plotted as a tick on top, plus a one-line summary
/// (e.g. *"Dein Bestwert liegt im typischen Bereich"*). Tapping the
/// band opens `BenchmarkSourceSheet` with the source label + the
/// "kein medizinischer Befund" disclaimer.
///
/// **Slot in the screen:** between `MilestoneStrip` and the footer.
/// The parent passes one band per record-kind that the provider
/// carries data for; kinds returning `nil` from
/// `ClinicalBenchmarkProvider.benchmark(for:)` are skipped.
///
/// **Theme-2.0 contract:** the band uses the mono surface scale
/// (`HLSurface.tertiary` recessed well + `HLAccent.userBrandTint`
/// for the user tick + `HLText.secondary` for the band stripe). No
/// per-kind tinting on this surface — the comparison band is a
/// data-rich callout, not a chart.
///
/// **Accessibility:** collapsed to one VoiceOver element with the
/// summary line + the user value + the typical range, so users don't
/// have to swipe through the geometry.
struct ComparisonBand: View {
    let record: PersonalRecord
    let benchmark: ClinicalBenchmark
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                header
                bar
                summary
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(HLSpace.lg)
            .background(HLSurface.secondary, in: RoundedRectangle(cornerRadius: HLRadius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: HLRadius.card, style: .continuous)
                    .stroke(HLColor.separator, lineWidth: 0.5)
            }
        }
        .buttonStyle(HLPressableButtonStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(Text(LocalizedStringKey(Layout.accessibilityHint)))
    }

    // MARK: - Subviews

    private var header: some View {
        HStack(spacing: HLSpace.xs) {
            Image(systemName: "chart.bar.xaxis")
                .font(.hlIcon(HLIconSize.rowAction))
                .foregroundStyle(HLText.secondary)
                .accessibilityHidden(true)
            HLSectionLabel(LocalizedStringKey(Layout.eyebrow))
            Spacer(minLength: 0)
            Text(metricLabel)
                .font(.hlCaption.weight(.semibold))
                .foregroundStyle(HLText.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    private var bar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // Track — full chart range.
                Capsule()
                    .fill(HLSurface.tertiary)
                    .frame(height: Layout.trackHeight)

                // Reference band — population mean ± 1σ.
                let bandRect = bandRect(in: geo.size.width)
                Capsule()
                    .fill(HLText.secondary.opacity(HLOpacity.surfaceTintStrong))
                    .frame(width: bandRect.width, height: Layout.trackHeight)
                    .offset(x: bandRect.minX)

                // Mean marker — center tick of the band.
                if let meanX = meanX(in: geo.size.width) {
                    Rectangle()
                        .fill(HLText.secondary)
                        .frame(width: 1, height: Layout.trackHeight)
                        .offset(x: meanX)
                }

                // User value tick — accent-coloured pill so it reads
                // as "your value" against the mono band.
                if let userX = userX(in: geo.size.width) {
                    Capsule()
                        .fill(HLAccent.userBrandTint)
                        .frame(width: Layout.tickWidth, height: Layout.trackHeight + 6)
                        .offset(x: userX - Layout.tickWidth / 2, y: -3)
                }
            }
            .frame(width: geo.size.width, height: Layout.trackHeight + 6, alignment: .leading)
        }
        .frame(height: Layout.trackHeight + 6)
    }

    private var summary: some View {
        HStack(alignment: .firstTextBaseline, spacing: HLSpace.xs) {
            Text(summaryLine)
                .font(.hlSubhead)
                .foregroundStyle(HLText.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Image(systemName: "info.circle")
                .font(.hlIcon(HLIconSize.rowAction))
                .foregroundStyle(HLText.tertiary)
                .accessibilityHidden(true)
        }
    }

    // MARK: - Geometry

    /// Chart's X-domain. Picks `min(bandLow, userValue)` and
    /// `max(bandHigh, userValue, clinicalCeiling?)` so the user tick
    /// always lands inside the visible track, even if the value is
    /// far from the population band (e.g. a 25 000 step day vs. a
    /// 7 500 mean).
    private var domain: ClosedRange<Double> {
        let userValue = record.base.value
        var lo = min(benchmark.bandLow, userValue)
        var hi = max(benchmark.bandHigh, userValue)
        if let floor = benchmark.clinicalFloor {
            lo = min(lo, floor)
        }
        if let ceiling = benchmark.clinicalCeiling {
            hi = max(hi, ceiling)
        }
        // Pad 8% on each side so the user tick + mean marker don't
        // sit flush with the capsule edges.
        let span = max(hi - lo, 1)
        let pad = span * 0.08
        return (lo - pad) ... (hi + pad)
    }

    private func position(for value: Double, in width: CGFloat) -> CGFloat? {
        let range = domain
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return nil }
        let ratio = (value - range.lowerBound) / span
        return CGFloat(ratio) * width
    }

    private func bandRect(in width: CGFloat) -> (minX: CGFloat, width: CGFloat) {
        guard let lo = position(for: benchmark.bandLow, in: width),
              let hi = position(for: benchmark.bandHigh, in: width) else
        {
            return (0, 0)
        }
        return (lo, max(0, hi - lo))
    }

    private func meanX(in width: CGFloat) -> CGFloat? {
        position(for: benchmark.mean, in: width)
    }

    private func userX(in width: CGFloat) -> CGFloat? {
        position(for: record.base.value, in: width)
    }

    // MARK: - Copy

    private var metricLabel: String {
        if let kind = record.kind {
            return kind.displayName
        }
        return MetricTypeLocalisation.label(forType: record.base.metricType)
    }

    private var summaryLine: String {
        let region = benchmark.classify(record.base.value)
        switch (region, benchmark.favorability) {
        case (.insideBand, _):
            return Layout.summaryInsideBand
        case (.belowBand, .lowerIsBetter):
            return Layout.summaryBelowBetter
        case (.belowBand, .higherIsBetter):
            return Layout.summaryBelowWorse
        case (.belowBand, .centered):
            return Layout.summaryBelowCentered
        case (.aboveBand, .lowerIsBetter):
            return Layout.summaryAboveWorse
        case (.aboveBand, .higherIsBetter):
            return Layout.summaryAboveBetter
        case (.aboveBand, .centered):
            return Layout.summaryAboveCentered
        }
    }

    private var accessibilityLabel: Text {
        let userValue = Self.numberFormatter.string(from: NSNumber(value: record.base.value)) ?? "\(record.base.value)"
        let lo = Self.numberFormatter.string(from: NSNumber(value: benchmark.bandLow)) ?? "\(benchmark.bandLow)"
        let hi = Self.numberFormatter.string(from: NSNumber(value: benchmark.bandHigh)) ?? "\(benchmark.bandHigh)"
        let unit = record.base.unit
        let unitSuffix = unit.isEmpty ? "" : " \(unit)"
        return Text(
            "\(metricLabel) Vergleich. Dein Wert: \(userValue)\(unitSuffix). Typischer Bereich: \(lo) bis \(hi)\(unitSuffix). \(summaryLine)"
        )
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

extension ComparisonBand {
    enum Layout {
        static let trackHeight: CGFloat = 10
        static let tickWidth: CGFloat = 6

        static let eyebrow = "Vergleichsbereich"
        static let accessibilityHint = "Tippen, um Quellen und Hinweise zu öffnen."

        static let summaryInsideBand = "Dein Bestwert liegt im typischen Bereich."
        static let summaryBelowBetter = "Dein Bestwert liegt unter dem Durchschnitt — das ist günstig."
        static let summaryBelowWorse = "Dein Bestwert liegt unter dem typischen Bereich."
        static let summaryBelowCentered = "Dein Bestwert liegt unterhalb des typischen Bereichs."
        static let summaryAboveWorse = "Dein Bestwert liegt über dem typischen Bereich."
        static let summaryAboveBetter = "Dein Bestwert liegt über dem Durchschnitt — das ist günstig."
        static let summaryAboveCentered = "Dein Bestwert liegt oberhalb des typischen Bereichs."
    }
}

#Preview("ComparisonBand — Schritte (above-band, better)") {
    let dto = PersonalRecordDTO(
        id: "preview.steps",
        userId: "u1",
        metricType: "ACTIVITY_STEPS",
        metricSlot: "Bester Tag",
        direction: .max,
        value: 18500,
        unit: "Steps",
        achievedAt: Date(),
        sourceMeasurementId: nil,
        source: "HEALTHKIT",
        externalId: nil,
        createdAt: Date()
    )
    let record = PersonalRecord(
        id: dto.id,
        base: dto,
        kind: .steps,
        sparklineValues: [],
        peakIndex: nil,
        previousValue: nil,
        bucket: .month,
        impressiveness: 0.7
    )
    let benchmark = ClinicalBenchmark(
        mean: 7500,
        sigma: 3000,
        clinicalFloor: nil,
        clinicalCeiling: nil,
        favorability: .higherIsBetter,
        sourceLabel: "Tudor-Locke et al. 2011 + CDC BRFSS 2019-2023"
    )
    return ComparisonBand(record: record, benchmark: benchmark, onTap: {})
        .padding()
        .background(HLSurface.primary)
}
