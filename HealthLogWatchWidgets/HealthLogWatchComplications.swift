import SwiftUI
import WidgetKit

// MARK: - HealthLog watch complications

//
// **v0.12 P2 / v0.15.2 W-WATCH-COMPLICATIONS — watch-face complications.**
// Glanceable next-due dose + today's compliance, the Personal Health Score
// ring, and the latest measurement on the watch face. Each reads the
// `WatchSnapshot` the watch app persists into the shared App Group container
// (`WatchSnapshotStore`), which the app keeps fresh from the phone's
// WatchConnectivity push — so the complications are offline-safe and never do a
// network round-trip. Every numeric branch is `.isFinite`-guarded / clamped and
// degrades to an em-dash when the value is absent.

@main
struct HealthLogWatchWidgetsBundle: WidgetBundle {
    var body: some Widget {
        NextDoseComplication()
        HealthScoreComplication()
        LatestMeasurementComplication()
    }
}

// MARK: - Deep links (open the WATCH app to the matching tab)

enum WatchComplicationDeepLink {
    static let nextDose = URL(string: "healthlog://medications")
    static let measurement = URL(string: "healthlog://measure")
    /// The watch has no in-app score surface; tapping the score ring opens the
    /// app to its default (Medications) view rather than a dead link.
    static let healthScore = URL(string: "healthlog://medications")
}

// MARK: - Em-dash helper

enum WatchComplicationFormat {
    /// The canonical "no value" glyph the complications paint when a reading is
    /// absent or non-finite — mirrors the app/widget em-dash doctrine.
    static let emDash = "—"
}

// MARK: - Staleness (audit-v0162 M3)

/// **Watch-side mirror of `WidgetTimelinePolicy`'s staleness rule.**
///
/// The complications read the last `WatchSnapshot` the phone pushed. When the
/// phone hasn't pushed in a long time (asleep / out of range across a weekend)
/// that snapshot's next-dose + today's counts go stale — but the 15-min
/// re-read backstop just re-reads the SAME stale blob, so a Lock-Screen-style
/// glance would keep showing Friday's dose / Friday's ring as if it were
/// today's. The complication target compiles neither `HealthLog/WidgetShared`
/// nor the app target, so it can't call `WidgetTimelinePolicy` directly; this
/// mirrors its thresholds VERBATIM (16 h next-dose cutoff; compliance cut at
/// the local-day rollover, 24 h max age). The numbers are the single rule the
/// tests pin on `WidgetTimelinePolicy` — keep them in sync.
enum WatchComplicationStaleness {
    /// Mirror of `WidgetTimelinePolicy.nextDoseStaleThreshold`.
    static let nextDoseThreshold: TimeInterval = 16 * 60 * 60
    /// Mirror of `WidgetTimelinePolicy.complianceStaleMaxAge`.
    static let complianceMaxAge: TimeInterval = 24 * 60 * 60

    /// `true` when the snapshot's next dose is too old to trust (suppress it).
    static func isNextDoseStale(generatedAt: Date, now: Date = Date()) -> Bool {
        now.timeIntervalSince(generatedAt) > nextDoseThreshold
    }

    /// `true` when the snapshot's today-counts are no longer today's: a prior
    /// local day (midnight rollover) or > 24 h old.
    static func isComplianceStale(
        generatedAt: Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Bool {
        if !calendar.isDate(generatedAt, inSameDayAs: now) { return true }
        return now.timeIntervalSince(generatedAt) > complianceMaxAge
    }
}

// MARK: - Next dose + today's compliance

struct NextDoseEntry: TimelineEntry {
    let date: Date
    let snapshot: WatchSnapshot
    /// audit-v0162 M3 — next dose too old to trust (suppress the dose glance).
    var isDoseStale: Bool = false
    /// audit-v0162 M3 — today-counts from an earlier local day / > 24 h old.
    var isComplianceStale: Bool = false
}

struct NextDoseProvider: TimelineProvider {
    func placeholder(in _: Context) -> NextDoseEntry {
        NextDoseEntry(date: Date(), snapshot: .placeholder)
    }

    func getSnapshot(in _: Context, completion: @escaping (NextDoseEntry) -> Void) {
        completion(makeEntry(WatchSnapshotStore().read() ?? .placeholder))
    }

    func getTimeline(in _: Context, completion: @escaping (Timeline<NextDoseEntry>) -> Void) {
        let entry = makeEntry(WatchSnapshotStore().read() ?? .placeholder)
        // Re-read every 15 min so the next-dose / compliance stays current even
        // without a fresh push (the watch app reloads on every push too).
        let next = Date().addingTimeInterval(15 * 60)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    private func makeEntry(_ snapshot: WatchSnapshot) -> NextDoseEntry {
        let now = Date()
        return NextDoseEntry(
            date: now,
            snapshot: snapshot,
            isDoseStale: WatchComplicationStaleness.isNextDoseStale(generatedAt: snapshot.generatedAt, now: now),
            isComplianceStale: WatchComplicationStaleness.isComplianceStale(generatedAt: snapshot.generatedAt, now: now)
        )
    }
}

struct NextDoseComplication: Widget {
    let kind = "dev.healthlog.app.watch.nextDose"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NextDoseProvider()) { entry in
            NextDoseComplicationView(
                snapshot: entry.snapshot,
                isDoseStale: entry.isDoseStale,
                isComplianceStale: entry.isComplianceStale
            )
            .containerBackground(.clear, for: .widget)
            .widgetURL(WatchComplicationDeepLink.nextDose)
        }
        // Localized via the widget extension's own Localizable.xcstrings (the
        // gallery name/description render English-only otherwise for DE).
        .configurationDisplayName(LocalizedStringResource("Next dose"))
        .description(LocalizedStringResource("Your next medication dose and today's adherence."))
        .supportedFamilies([
            .accessoryCircular,
            .accessoryCorner,
            .accessoryInline,
            .accessoryRectangular
        ])
    }
}

private struct NextDoseComplicationView: View {
    @Environment(\.widgetFamily) private var family
    let snapshot: WatchSnapshot
    /// audit-v0162 M3 — when set, suppress the (out-of-date) next dose glance.
    var isDoseStale = false
    /// audit-v0162 M3 — when set, the today-counts are yesterday's: show em-dash.
    var isComplianceStale = false

    /// The soonest actionable dose, or `nil` when there is none — OR when the
    /// snapshot is too stale to trust it (audit-v0162 M3): a stale dose must
    /// never be surfaced as if it were still due today.
    private var nextDose: WatchSnapshot.Dose? {
        guard !isDoseStale else { return nil }
        return snapshot.doses.first { $0.isActionable }
    }

    /// Compliance ring fill — 0 while stale so yesterday's fraction isn't
    /// painted as today's.
    private var complianceFraction: Double {
        isComplianceStale ? 0 : snapshot.complianceFraction
    }

    /// Centre count text — an em-dash while the counts are stale.
    private var takenText: String {
        isComplianceStale ? WatchComplicationFormat.emDash : "\(snapshot.takenCount)"
    }

    /// "x/y" today-counts line — em-dash while stale.
    private var countsText: String {
        isComplianceStale
            ? WatchComplicationFormat.emDash
            : "\(snapshot.takenCount)/\(snapshot.scheduledCount)"
    }

    var body: some View {
        switch family {
        case .accessoryInline:
            inline
        case .accessoryCircular:
            circular
        case .accessoryCorner:
            corner
        case .accessoryRectangular:
            rectangular
        default:
            circular
        }
    }

    private var inline: some View {
        if let dose = nextDose {
            // W-RECONCILE H1 — redact the diagnosis-implying med name when the
            // wrist is down / face locked / always-on dimmed.
            Label {
                Text("\(dose.medicationName) \(dose.scheduledAt, format: .dateTime.hour().minute())")
            } icon: {
                Image(systemName: dose.isInjection ? "syringe" : "pills.fill")
            }
            .privacySensitive()
        } else if isDoseStale {
            // audit-v0162 M3 — snapshot too old to trust: prompt to open the app
            // instead of an "All done" that could be a false reassurance.
            Label("Open iPhone app", systemImage: "exclamationmark.arrow.circlepath")
                .privacySensitive()
        } else {
            // `.privacySensitive()` here only to unify the branch type with the
            // redacted dose branch; "All done" carries no PHI.
            Label("All done", systemImage: "checkmark.circle")
                .privacySensitive()
        }
    }

    private var circular: some View {
        Gauge(value: complianceFraction) {
            Image(systemName: isComplianceStale ? "exclamationmark.arrow.circlepath" : "pills.fill")
        } currentValueLabel: {
            Text(takenText)
        }
        .gaugeStyle(.accessoryCircularCapacity)
    }

    private var corner: some View {
        Image(systemName: cornerSymbol)
            .font(.title2)
            .widgetLabel {
                if let dose = nextDose {
                    Text("\(dose.scheduledAt, format: .dateTime.hour().minute())")
                } else if isDoseStale {
                    Text("Open iPhone app")
                } else {
                    Text("All done")
                }
            }
    }

    private var cornerSymbol: String {
        if isDoseStale { return "exclamationmark.arrow.circlepath" }
        return nextDose == nil ? "checkmark.circle.fill" : "pills.fill"
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let dose = nextDose {
                Label {
                    // W-RECONCILE H1 — redact PHI med name on the locked/dimmed face.
                    Text(dose.medicationName).font(.headline).lineLimit(1).privacySensitive()
                } icon: {
                    Image(systemName: dose.isInjection ? "syringe" : "pills.fill")
                }
                Text("\(dose.scheduledAt, format: .dateTime.hour().minute())")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if isDoseStale {
                Label("Open iPhone app", systemImage: "exclamationmark.arrow.circlepath")
                    .font(.headline)
            } else {
                Label("All done", systemImage: "checkmark.circle")
                    .font(.headline)
            }
            Text(countsText)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Personal Health Score ring

struct HealthScoreEntry: TimelineEntry {
    let date: Date
    let glance: WatchSnapshot.HealthScoreGlance?
}

struct HealthScoreProvider: TimelineProvider {
    func placeholder(in _: Context) -> HealthScoreEntry {
        HealthScoreEntry(date: Date(), glance: nil)
    }

    func getSnapshot(in _: Context, completion: @escaping (HealthScoreEntry) -> Void) {
        completion(HealthScoreEntry(date: Date(), glance: WatchSnapshotStore().read()?.healthScore))
    }

    func getTimeline(in _: Context, completion: @escaping (Timeline<HealthScoreEntry>) -> Void) {
        let glance = WatchSnapshotStore().read()?.healthScore
        let entry = HealthScoreEntry(date: Date(), glance: glance)
        let next = Date().addingTimeInterval(15 * 60)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

struct HealthScoreComplication: Widget {
    let kind = "dev.healthlog.app.watch.healthScore"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: HealthScoreProvider()) { entry in
            HealthScoreComplicationView(glance: entry.glance)
                .containerBackground(.clear, for: .widget)
                .widgetURL(WatchComplicationDeepLink.healthScore)
        }
        .configurationDisplayName(LocalizedStringResource("Health score"))
        .description(LocalizedStringResource("Your latest Personal Health Score."))
        .supportedFamilies([
            .accessoryCircular,
            .accessoryCorner
        ])
    }
}

/// Maps the resolved band (shared `HealthScoreGlance.signalBand`, tested in
/// `HealthLogTests`) onto the signal colour, mirroring the in-app `HLScoreRing`
/// / phone score widget: green ≥ 70 / yellow ≥ 40 / red.
enum WatchHealthScoreSignal {
    static func color(for glance: WatchSnapshot.HealthScoreGlance) -> Color {
        switch glance.signalBand {
        case "green": LAColor.success
        case "yellow": LAColor.warn
        default: LAColor.danger
        }
    }
}

private struct HealthScoreComplicationView: View {
    @Environment(\.widgetFamily) private var family
    let glance: WatchSnapshot.HealthScoreGlance?

    /// Clamped 0…1 ring fraction. Absent score → empty ring (0).
    private var fraction: Double {
        glance?.fraction ?? 0
    }

    /// The centre value text: the 0…100 score or an em-dash when absent. The
    /// glance score is already clamped 0…100 on construction (finite by type).
    private var valueText: String {
        guard let score = glance?.score else { return WatchComplicationFormat.emDash }
        return "\(score)"
    }

    private var tint: Color {
        guard let glance else { return LAColor.textSecondary }
        return WatchHealthScoreSignal.color(for: glance)
    }

    var body: some View {
        switch family {
        case .accessoryCorner:
            corner
        default:
            circular
        }
    }

    private var circular: some View {
        Gauge(value: fraction) {
            Image(systemName: "heart.fill")
        } currentValueLabel: {
            Text(valueText)
        }
        .gaugeStyle(.accessoryCircular)
        .tint(tint)
    }

    private var corner: some View {
        Text(valueText)
            .font(.title2)
            .widgetLabel {
                Gauge(value: fraction) {
                    Text(verbatim: "")
                }
                .tint(tint)
            }
    }
}

// MARK: - Latest measurement

struct LatestMeasurementEntry: TimelineEntry {
    let date: Date
    let measurement: WatchSnapshot.LatestMeasurement?
}

struct LatestMeasurementProvider: TimelineProvider {
    func placeholder(in _: Context) -> LatestMeasurementEntry {
        LatestMeasurementEntry(date: Date(), measurement: nil)
    }

    func getSnapshot(in _: Context, completion: @escaping (LatestMeasurementEntry) -> Void) {
        completion(LatestMeasurementEntry(date: Date(), measurement: WatchSnapshotStore().read()?.latestMeasurement))
    }

    func getTimeline(in _: Context, completion: @escaping (Timeline<LatestMeasurementEntry>) -> Void) {
        let measurement = WatchSnapshotStore().read()?.latestMeasurement
        let entry = LatestMeasurementEntry(date: Date(), measurement: measurement)
        let next = Date().addingTimeInterval(15 * 60)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

struct LatestMeasurementComplication: Widget {
    let kind = "dev.healthlog.app.watch.latestMeasurement"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: LatestMeasurementProvider()) { entry in
            LatestMeasurementComplicationView(measurement: entry.measurement)
                .containerBackground(.clear, for: .widget)
                .widgetURL(WatchComplicationDeepLink.measurement)
        }
        .configurationDisplayName(LocalizedStringResource("Latest measurement"))
        .description(LocalizedStringResource("Your most recent measurement reading."))
        .supportedFamilies([
            .accessoryCircular,
            .accessoryRectangular
        ])
    }
}

private struct LatestMeasurementComplicationView: View {
    @Environment(\.widgetFamily) private var family
    let measurement: WatchSnapshot.LatestMeasurement?

    /// The pre-formatted value (already em-dash for a non-finite reading
    /// phone-side), or an em-dash when no measurement has loaded.
    private var valueText: String {
        measurement?.formattedValue ?? WatchComplicationFormat.emDash
    }

    private var symbol: String {
        measurement?.symbol ?? "waveform.path.ecg"
    }

    var body: some View {
        switch family {
        case .accessoryRectangular:
            rectangular
        default:
            circular
        }
    }

    private var circular: some View {
        VStack(spacing: 0) {
            Image(systemName: symbol)
                .font(.caption2)
            Text(valueText)
                .font(.system(.headline, design: .rounded))
                .minimumScaleFactor(0.6)
                .lineLimit(1)
        }
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let measurement {
                Label {
                    Text(measurement.title).font(.headline).lineLimit(1)
                } icon: {
                    Image(systemName: measurement.symbol)
                }
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(measurement.formattedValue)
                        .font(.system(.body, design: .rounded))
                    if !measurement.unit.isEmpty {
                        Text(measurement.unit)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(measurement.recordedAt, format: .relative(presentation: .named))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Label("No measurements yet", systemImage: "waveform.path.ecg")
                    .font(.headline)
            }
        }
    }
}
