import SwiftUI
import WidgetKit

/// **v0.15 companion-#3 — latest-measurement glance widget.**
///
/// `systemSmall` + Lock-Screen `accessoryRectangular` + `accessoryInline`.
/// Shows the most recent reading the app holds — the metric title, its
/// pre-formatted value + unit, and a relative timestamp. The app formats the
/// value through the canonical `MetricKindDescriptor` formatter + the user's
/// unit preferences (see `WidgetSnapshot.LatestMeasurement.make`), so the
/// widget shows the SAME string the dashboard tile renders. Reads the App Group
/// snapshot — no network in the widget process, no recompute (server-first).
/// Non-interactive: tapping opens the app to Insights.
///
/// **Default metric:** the newest reading across all kinds — the glanceable
/// "your last measurement". A fixed sensible default (no per-metric picker) so
/// the widget stays a one-tap glance; the in-app Insights surface is the place
/// to drill into a specific metric.
struct LatestMeasurementWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetKind.latestMeasurement, provider: LatestMeasurementProvider()) { entry in
            LatestMeasurementWidgetView(entry: entry)
                .containerBackground(LAColor.surface, for: .widget)
        }
        .configurationDisplayName(Text("widget.latest_measurement.title"))
        .description(Text("widget.latest_measurement.description"))
        .supportedFamilies([.systemSmall, .accessoryRectangular, .accessoryInline])
    }
}

// MARK: - Timeline entry + provider

struct LatestMeasurementEntry: TimelineEntry {
    let date: Date
    let latest: WidgetSnapshot.LatestMeasurement?
}

/// Reads the App Group snapshot. The latest reading only changes when the app
/// loads/captures a measurement (app-driven `reloadTimelines`); the relative
/// timestamp drifts on its own, so the timeline reloads on a modest periodic
/// backstop so "vor 2 Std." stays roughly honest without burning the budget.
struct LatestMeasurementProvider: TimelineProvider {
    private let store: WidgetSnapshotStore

    init(store: WidgetSnapshotStore = WidgetSnapshotStore()) {
        self.store = store
    }

    func placeholder(in _: Context) -> LatestMeasurementEntry {
        LatestMeasurementEntry(date: .now, latest: nil)
    }

    func getSnapshot(in _: Context, completion: @escaping @Sendable (LatestMeasurementEntry) -> Void) {
        let snapshot = store.read() ?? .placeholder
        completion(LatestMeasurementEntry(date: .now, latest: snapshot.latestMeasurement))
    }

    func getTimeline(in _: Context, completion: @escaping @Sendable (Timeline<LatestMeasurementEntry>) -> Void) {
        let now = Date.now
        let snapshot = store.read() ?? .placeholder
        let entry = LatestMeasurementEntry(date: now, latest: snapshot.latestMeasurement)
        // Reload hourly so the relative-time line stays roughly current even if
        // the app never opens (the next-dose backstop cadence, reused).
        let reload = now.addingTimeInterval(60 * 60)
        completion(Timeline(entries: [entry], policy: .after(reload)))
    }
}

// MARK: - Views

private struct LatestMeasurementWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: LatestMeasurementEntry

    var body: some View {
        switch family {
        case .accessoryInline:
            accessoryInline
        case .accessoryRectangular:
            accessoryRectangular
        default:
            homeSmall
        }
    }

    // MARK: Home-screen

    private var homeSmall: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            Spacer(minLength: 0)
            if let latest = entry.latest {
                valueLine(latest)
                Text(relativeLine(latest.recordedAt))
                    .font(.caption2)
                    .foregroundStyle(LAColor.textSecondary)
                    .lineLimit(1)
            } else {
                Text("widget.latest_measurement.empty")
                    .font(.subheadline)
                    .foregroundStyle(LAColor.textSecondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(deepLink)
    }

    private var header: some View {
        Label {
            Text(entry.latest?.title ?? String(localized: "widget.latest_measurement.header"))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(LAColor.textSecondary)
                .lineLimit(1)
        } icon: {
            Image(systemName: entry.latest?.symbol ?? "waveform.path.ecg")
                .foregroundStyle(LAColor.accent)
        }
        .labelStyle(.titleAndIcon)
    }

    private func valueLine(_ latest: WidgetSnapshot.LatestMeasurement) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(latest.formattedValue)
                .font(.title.weight(.semibold))
                .foregroundStyle(LAColor.text)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            if !latest.unit.isEmpty {
                Text(latest.unit)
                    .font(.caption)
                    .foregroundStyle(LAColor.textSecondary)
            }
        }
    }

    // MARK: Lock-Screen accessories

    private var accessoryRectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let latest = entry.latest {
                Label {
                    Text(latest.title).lineLimit(1)
                } icon: {
                    Image(systemName: latest.symbol)
                }
                .font(.caption.weight(.semibold))
                Text(valueWithUnit(latest))
                    .font(.headline)
                    .lineLimit(1)
                    // Lock-screen accessory: redact the measurement value when
                    // the device is locked (QA-b198 Sec-L-3 — PHI on lock).
                    .privacySensitive()
                Text(relativeLine(latest.recordedAt))
                    .font(.caption2)
                    .lineLimit(1)
            } else {
                Label {
                    Text("widget.latest_measurement.empty")
                } icon: {
                    Image(systemName: "waveform.path.ecg")
                }
                .font(.headline)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetAccessibilityLabel(accessoryLabel)
    }

    private var accessoryInline: some View {
        Label {
            inlineText
        } icon: {
            Image(systemName: entry.latest?.symbol ?? "waveform.path.ecg")
        }
        // The inline string carries the measurement value — redact on lock
        // (QA-b198 Sec-L-3).
        .privacySensitive()
        .widgetAccessibilityLabel(accessoryLabel)
    }

    private var inlineText: Text {
        if let latest = entry.latest {
            Text(latest.title) + Text(" ") + Text(valueWithUnit(latest))
        } else {
            Text("widget.latest_measurement.empty")
        }
    }

    private var accessoryLabel: Text {
        if let latest = entry.latest {
            Text(latest.title) + Text(": ") + Text(valueWithUnit(latest))
        } else {
            Text("widget.latest_measurement.empty")
        }
    }

    // MARK: Copy helpers

    /// "72.4 kg" — value + unit, eliding an empty unit.
    private func valueWithUnit(_ latest: WidgetSnapshot.LatestMeasurement) -> String {
        latest.unit.isEmpty ? latest.formattedValue : "\(latest.formattedValue) \(latest.unit)"
    }

    /// "vor 2 Std." — relative time since the reading. Uses the system relative
    /// formatter so it localizes + abbreviates honestly.
    private func relativeLine(_ date: Date) -> String {
        date.formatted(.relative(presentation: .named))
    }

    /// Deep link the whole-tile tap opens — the SPECIFIC metric page in the
    /// in-app Insights surface (`healthlog://insights/<kebab-slug>`), resolved
    /// from the snapshot reading's `kindRaw` via the canonical
    /// `InsightsLatestMeasurementDeepLink.url(forKindRaw:)`. Falls back to the
    /// Insights root when the kind has no Insights page (or there is no reading),
    /// so a tap never dead-ends or produces a broken URL.
    private var deepLink: URL? {
        InsightsLatestMeasurementDeepLink.url(forKindRaw: entry.latest?.kindRaw)
    }
}

private extension View {
    func widgetAccessibilityLabel(_ label: Text) -> some View {
        accessibilityElement().accessibilityLabel(label)
    }
}
