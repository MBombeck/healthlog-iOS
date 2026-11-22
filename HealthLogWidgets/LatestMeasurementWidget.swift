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
/// **Configurable metric.** The person picks which metric the tile shows; the
/// choice "Zuletzt erfasst" is the default and is the newest reading across all
/// kinds, exactly what the tile showed before it became configurable. A widget
/// placed earlier carries no choice, resolves to that default, and so renders
/// as it did: the families it had are laid out as they were, with no trend.
/// A picked metric adds a small daily trend to every family that has room.
struct LatestMeasurementWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: WidgetKind.latestMeasurement,
            intent: MeasurementWidgetIntent.self,
            provider: LatestMeasurementProvider()
        ) { entry in
            LatestMeasurementWidgetView(entry: entry)
                .containerBackground(LAColor.surface, for: .widget)
        }
        .configurationDisplayName(Text("widget.latest_measurement.title"))
        .description(Text("widget.metric.description"))
        .supportedFamilies([
            .systemSmall, .systemMedium, .systemLarge, .systemExtraLarge,
            .accessoryCircular, .accessoryRectangular, .accessoryInline
        ])
    }
}

// MARK: - Timeline entry + provider

/// Reads the App Group snapshot. The latest reading only changes when the app
/// loads/captures a measurement (app-driven `reloadTimelines`); the relative
/// timestamp drifts on its own, so the timeline reloads on a modest periodic
/// backstop so "vor 2 Std." stays roughly honest without burning the budget.
struct LatestMeasurementProvider: AppIntentTimelineProvider {
    private let store: WidgetSnapshotStore

    init(store: WidgetSnapshotStore = WidgetSnapshotStore()) {
        self.store = store
    }

    func placeholder(in _: Context) -> LatestMeasurementEntry {
        LatestMeasurementEntry(date: .now, latest: nil)
    }

    /// No preset configurations on iPhone and iPad: there the person picks the
    /// metric in the widget's edit sheet. Building an `AppIntentRecommendation`
    /// in this extension trapped inside WidgetKit (EXC_BREAKPOINT on every
    /// timeline load, 18.11.2026), which took the whole extension down.
    func recommendations() -> [AppIntentRecommendation<MeasurementWidgetIntent>] {
        []
    }

    func snapshot(for configuration: MeasurementWidgetIntent, in _: Context) async -> LatestMeasurementEntry {
        entry(for: configuration, now: .now)
    }

    func timeline(for configuration: MeasurementWidgetIntent, in _: Context) async -> Timeline<LatestMeasurementEntry> {
        let now = Date.now
        // Reload hourly so the relative-time line stays roughly current even if
        // the app never opens (the next-dose backstop cadence, reused).
        return Timeline(
            entries: [entry(for: configuration, now: now)],
            policy: .after(now.addingTimeInterval(60 * 60))
        )
    }

    private func entry(for configuration: MeasurementWidgetIntent, now: Date) -> LatestMeasurementEntry {
        let snapshot = store.read() ?? .placeholder
        return LatestMeasurementEntry(
            date: now,
            resolved: WidgetMetricSelection.resolve(snapshot: snapshot, choice: configuration.choice),
            pickedTitle: configuration.choice == nil ? nil : configuration.metric?.title
        )
    }
}

// MARK: - Views
