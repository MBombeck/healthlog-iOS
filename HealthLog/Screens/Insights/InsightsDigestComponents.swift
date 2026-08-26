import SwiftUI

// MARK: - Alerts list

// v0.14.3 C4 — `BMICard` + `BPStatusCard` were retired here. Both folded into
// the ONE canonical `InsightsMetricStatusCard` (driven by
// `InsightsMetricStatusDescriptor`), so EVERY metric — BP, BMI, Puls, Gewicht,
// Ruhepuls, … — now renders the IDENTICAL "30 Tage Durchschnitt" card instead
// of three divergent ones behind a `kind == .bloodPressure` fork. The WHO /
// ESH classification label + tone logic moved verbatim into the descriptor
// builder.

/// Renders `comprehensive.alerts[]` — server-emitted health alerts (BMI,
/// BP, weight trend, pulse anomalies, medication compliance). Server source:
/// `src/lib/analytics/classifications.ts:generateAlerts()`.
public struct AlertsList: View {
    let alerts: [HealthAlert]

    public init(alerts: [HealthAlert]) {
        self.alerts = alerts
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: HLSpace.sm) {
            // #57 — Insights sentence-case header language. v0.14 DRIFT-9 — was a
            // German literal ("Hinweise") in the EN-source catalogue; localized
            // under a namespaced key (EN "Notes" / DE "Hinweise") so it doesn't
            // mis-key against the generic "Notes"→"Notizen" entry.
            InsightsSectionHeader("insights.digest.alerts.header")
            ForEach(alerts) { alert in
                AlertRow(alert: alert)
            }
        }
    }
}

private struct AlertRow: View {
    let alert: HealthAlert

    var body: some View {
        HLCard {
            HStack(alignment: .top, spacing: HLSpace.sm) {
                Image(systemName: symbol)
                    .foregroundStyle(color)
                    .imageScale(.large)
                    .padding(.top, HLSpace.xxs)
                VStack(alignment: .leading, spacing: HLSpace.xs) {
                    HStack {
                        Text(alert.title)
                            .font(.hlSubhead.weight(.semibold))
                            .foregroundStyle(HLText.primary)
                        Spacer()
                        HLBadge(levelLabel, tone: badgeTone)
                    }
                    Text(alert.message)
                        .font(.hlCaption)
                        .foregroundStyle(HLText.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch alert.level {
        case .success: "checkmark.seal.fill"
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .danger: "exclamationmark.octagon.fill"
        }
    }

    private var color: Color {
        // C-7: `.success`/`.warning`/`.danger` keep their semantic
        // traffic-light hues — these signal state the user should react to.
        // `.info` is neutral editorial content, dropped to `textSecondary`
        // so the digest stays monochrome unless something needs attention.
        switch alert.level {
        case .success: HLColor.statusOK
        case .info: HLText.secondary
        case .warning: HLColor.statusWarn
        case .danger: HLColor.statusBad
        }
    }

    private var levelLabel: String {
        switch alert.level {
        case .success: String(localized: "insights.digest.alert.success")
        case .info: String(localized: "insights.digest.alert.info")
        case .warning: String(localized: "insights.digest.alert.warning")
        case .danger: String(localized: "insights.digest.alert.danger")
        }
    }

    private var badgeTone: HLBadge.Tone {
        switch alert.level {
        case .success: .success
        case .info: .info
        case .warning: .warning
        case .danger: .critical
        }
    }
}

// MARK: - Mood summary card

//
// Server source: `comprehensive.moodSummary` — DataSummary over the 90-day
// mood entry series (`src/lib/analytics/trends.ts:summarize()`).
//
// v0.5.3 F-2 (operator walkthrough, 2026-05-17): die vorherige Version
// rahmte jeden Schnitt mit einem Smiley (😞 🙁 😐 🙂 😄). Operator
// flaggte das als "sehr weiß und stimmig … sehr schlicht und irgendwie
// nicht gut", weil der Rest der Insights-Seite (BMI, BP, Korrelationen,
// Charts) tonal-mono auf HLChartTints + HLText laeuft. Die Smileys
// rissen den Lesefluss visuell auseinander.
//
// Neu: pro Schnitt ein 1–5-Skala-Marker als horizontaler Tonal-Bar mit
// Tick-Marken bei 1/3/5 (mirror der RuleMarks im MoodTrendChart). Der
// Marker liegt auf dem Avg-Wert + ist mit HLChartTints.series getintet.
// Smileys bleiben funktional in der Mood-Auswahl (MoodScreen) — dort
// dienen sie der Wert-Bedeutung, nicht der Datendarstellung.

public struct MoodSummaryCard: View {
    let summary: MetricSummary

    /// Min/max der Stimmungsskala — gespiegelt aus MoodCopy.scoreLabel
    /// (Schlecht=1 .. Top=5) + MoodTrendChart-Y-Domain.
    private static let scaleMin: Double = 1
    private static let scaleMax: Double = 5

    public init(summary: MetricSummary) {
        self.summary = summary
    }

    public var body: some View {
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.md) {
                InsightsSectionHeader("Mood")
                HStack(alignment: .top, spacing: HLSpace.lg) {
                    averageColumn(
                        label: String(localized: "insights.mood.avg7"),
                        value: summary.avg7
                    )
                    averageColumn(
                        label: String(localized: "insights.mood.avg30"),
                        value: summary.avg30
                    )
                    countColumn(
                        label: String(localized: "Entries"),
                        count: summary.count
                    )
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    /// Two columns — `Ø 7 T` + `Ø 30 T` — share the same shape: numeric
    /// value on top, 1–5 scale bar underneath with a marker at the value.
    private func averageColumn(label: String, value: Double?) -> some View {
        VStack(alignment: .leading, spacing: HLSpace.xs) {
            Text(label)
                .font(.hlCaption)
                .foregroundStyle(HLText.tertiary)
            Text(formattedAverage(value))
                .font(.hlMetric(.title2))
                .foregroundStyle(HLText.primary)
                .monospacedDigit()
            scaleMarker(value: value)
                .frame(height: 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Right-hand column — single integer count, kein Skala-Bar
    /// (Anzahl gehoert nicht auf die 1–5-Achse).
    private func countColumn(label: String, count: Int?) -> some View {
        VStack(alignment: .leading, spacing: HLSpace.xs) {
            Text(label)
                .font(.hlCaption)
                .foregroundStyle(HLText.tertiary)
            Text(formattedCount(count))
                .font(.hlMetric(.title2))
                .foregroundStyle(HLText.primary)
                .monospacedDigit()
            // Placeholder strip with the same height as the scale bar so
            // the three columns share a baseline + the card sits balanced.
            Color.clear.frame(height: 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 1–5 scale rail with three ticks at 1 / 3 / 5 (mirror der dashed
    /// RuleMarks im `MoodTrendChart`) plus ein gefuellter Marker am
    /// aktuellen Avg-Wert in `HLChartTints.series`.
    private func scaleMarker(value: Double?) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // Rail.
                Capsule()
                    .fill(HLColor.backgroundEleva)
                // Ticks bei 1 / 3 / 5.
                ForEach([1.0, 3.0, 5.0], id: \.self) { tick in
                    Rectangle()
                        .fill(HLText.tertiary.opacity(0.5))
                        .frame(width: 1, height: 8)
                        .offset(x: geo.size.width * CGFloat(normalize(tick)))
                }
                // Marker.
                if let value, value.isFinite {
                    Circle()
                        // v0.6.1.25 Y10.7 (C3): operator brief — drop the
                        // purple-tinted marker, mood-summary card reads
                        // calmer with a neutral tertiary fill.
                        .fill(HLText.tertiary)
                        .frame(width: 8, height: 8)
                        .offset(x: max(0, geo.size.width * CGFloat(normalize(value)) - 4))
                }
            }
        }
    }

    /// Maps a 1…5 value to 0…1 on the rail. Clamps out-of-range values
    /// so a malformed server response never pushes the marker off-canvas.
    private func normalize(_ value: Double) -> Double {
        let clamped = min(max(value, Self.scaleMin), Self.scaleMax)
        return (clamped - Self.scaleMin) / (Self.scaleMax - Self.scaleMin)
    }

    private func formattedAverage(_ value: Double?) -> String {
        guard let value else { return "—" }
        return value.formatted(.number.precision(.fractionLength(1)))
    }

    private func formattedCount(_ count: Int?) -> String {
        guard let count else { return "—" }
        return count.formatted(.number)
    }

    /// VoiceOver-Zusammenfassung der drei Spalten in einem Atemzug.
    private var accessibilitySummary: String {
        let seven = summary.avg7.map { String(localized: "7-day avg \($0.formatted(.number.precision(.fractionLength(1))))") }
            ?? String(localized: "7-day avg no data")
        let thirty = summary.avg30.map { String(localized: "30-day avg \($0.formatted(.number.precision(.fractionLength(1))))") }
            ?? String(localized: "30-day avg no data")
        let entries = summary.count.map { String(localized: "\($0) entries") }
            ?? String(localized: "No entries")
        return String(localized: "Mood — \(seven), \(thirty), \(entries)")
    }
}

// MARK: - Data quality footer

//
// Server source: `comprehensive.dataSpanDays` + `comprehensive.totalMeasurements`.

public struct DataQualityFooter: View {
    let span: Int
    let measurements: Int

    public init(span: Int, measurements: Int) {
        self.span = span
        self.measurements = measurements
    }

    public var body: some View {
        Text(String(localized: "Analysis based on \(measurements) measurements over \(span) days."))
            .font(.hlCaption)
            .foregroundStyle(HLText.tertiary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, HLSpace.md)
            .accessibilityLabel(String(localized: "Data basis: \(measurements) measurements over \(span) days"))
    }
}
