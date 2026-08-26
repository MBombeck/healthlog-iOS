import SwiftUI
import WidgetKit

/// **v0.15 companion-#3 — Personal Health Score ring widget.**
///
/// `systemSmall` + Lock-Screen `accessoryCircular`. Renders the latest
/// server-resolved Personal Health Score (the daily wellness/condition score)
/// as a calm monochrome ring with the number, mirroring the in-app
/// ``HLScoreRing`` look (single-accent fill over a hairline track, the canonical
/// dark Tonal-Mono palette via ``LAColor``). Reads the App Group snapshot the
/// app writes (`WidgetSnapshotWriter.refreshHealthScore`) — no network in the
/// widget process, server-first (the score is mirrored verbatim, never
/// recomputed). Non-interactive: tapping opens the app to Insights.
struct HealthScoreWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetKind.healthScore, provider: HealthScoreProvider()) { entry in
            HealthScoreWidgetView(entry: entry)
                .containerBackground(LAColor.surface, for: .widget)
        }
        .configurationDisplayName(Text("widget.health_score.title"))
        .description(Text("widget.health_score.description"))
        .supportedFamilies([.systemSmall, .accessoryCircular])
    }
}

// MARK: - Timeline entry + provider

struct HealthScoreEntry: TimelineEntry {
    let date: Date
    let glance: WidgetSnapshot.HealthScoreGlance?
}

/// Reads the App Group snapshot. The score only moves when the dashboard
/// revalidates (app-driven `reloadTimelines`) or at the day boundary, so the
/// timeline backstops with a reload at the next local midnight plus the app's
/// explicit reloads for immediacy.
struct HealthScoreProvider: TimelineProvider {
    private let store: WidgetSnapshotStore

    init(store: WidgetSnapshotStore = WidgetSnapshotStore()) {
        self.store = store
    }

    func placeholder(in _: Context) -> HealthScoreEntry {
        HealthScoreEntry(date: .now, glance: nil)
    }

    func getSnapshot(in _: Context, completion: @escaping @Sendable (HealthScoreEntry) -> Void) {
        let snapshot = store.read() ?? .placeholder
        completion(HealthScoreEntry(date: .now, glance: snapshot.healthScore))
    }

    func getTimeline(in _: Context, completion: @escaping @Sendable (Timeline<HealthScoreEntry>) -> Void) {
        let now = Date.now
        let snapshot = store.read() ?? .placeholder
        let entry = HealthScoreEntry(date: now, glance: snapshot.healthScore)
        completion(Timeline(entries: [entry], policy: .after(WidgetTimelinePolicy.complianceReload(after: now))))
    }
}

// MARK: - Score band → signal mapping (widget-local, mirrors HLScoreRing)

enum HealthScoreSignal {
    /// The monochrome ring carries no per-score hue; the single status colour is
    /// reserved for the centre band word + the accessibility announcement. This
    /// maps the server band (or the numeric thresholds) to the sanctioned
    /// signal colour, matching `HLScoreRing.ScorePresentation`.
    static func color(band: String?, score: Int) -> Color {
        switch resolvedBand(band: band, score: score) {
        case "green": LAColor.success
        case "yellow": LAColor.warn
        default: LAColor.danger
        }
    }

    /// Localized band word (Strong / Fair / Low) for the centre label + a11y.
    static func word(band: String?, score: Int) -> String {
        switch resolvedBand(band: band, score: score) {
        case "green": String(localized: "widget.health_score.band.strong")
        case "yellow": String(localized: "widget.health_score.band.fair")
        default: String(localized: "widget.health_score.band.low")
        }
    }

    /// Prefer the server band; fall back to the 67/34 numeric thresholds (the
    /// same cutoffs `HealthScore.colorBand(forScore:)` uses) when absent.
    private static func resolvedBand(band: String?, score: Int) -> String {
        if let band, !band.isEmpty { return band }
        switch score {
        case 67...: return "green"
        case 34...: return "yellow"
        default: return "red"
        }
    }
}

// MARK: - Views

private struct HealthScoreWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: HealthScoreEntry

    var body: some View {
        switch family {
        case .accessoryCircular:
            accessoryCircular
        default:
            homeSmall
        }
    }

    private var homeSmall: some View {
        VStack(spacing: 8) {
            Label {
                Text("widget.health_score.header")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(LAColor.textSecondary)
            } icon: {
                Image(systemName: "heart.text.square.fill")
                    .foregroundStyle(LAColor.accent)
            }
            .labelStyle(.titleAndIcon)
            .frame(maxWidth: .infinity, alignment: .leading)

            if let glance = entry.glance {
                WidgetRing(
                    progress: glance.fraction,
                    value: "\(glance.score)",
                    caption: HealthScoreSignal.word(band: glance.band, score: glance.score)
                )
                // v1.35.0 (GH #83) — the Home widget is the number and nothing
                // else, so it carries the provenance mark: a chosen composition
                // is not the default one, and a widget that said nothing would
                // let a 82 out of five pillars read like a 82 out of eight.
                // Two words, under the ring, where the small family still has
                // room. The ring's own caption keeps the band word.
                if glance.configured {
                    Text("widget.health_score.configured")
                        .font(.caption2)
                        .foregroundStyle(LAColor.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            } else {
                emptyRing
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .widgetURL(Self.insightsDeepLink)
    }

    /// The neutral empty ring shown before a score has loaded / on logout.
    private var emptyRing: some View {
        WidgetRing(
            progress: 0,
            value: "—",
            caption: String(localized: "widget.health_score.empty")
        )
    }

    private var accessoryCircular: some View {
        Gauge(value: entry.glance?.fraction ?? 0) {
            Image(systemName: "heart.text.square.fill")
        } currentValueLabel: {
            Text(entry.glance.map { "\($0.score)" } ?? "—")
                .minimumScaleFactor(0.5)
                // Lock-screen accessory: redact the health-score value when the
                // device is locked (QA-b198 Sec-L-3 — PHI on the Lock Screen).
                .privacySensitive()
        }
        .gaugeStyle(.accessoryCircular)
        .widgetAccessibilityLabel(accessoryLabel)
    }

    private var accessoryLabel: Text {
        if let glance = entry.glance {
            // The lock-screen accessory has room for a two-digit number and
            // nothing else, so the mark reaches it through VoiceOver only —
            // where it costs no space and still qualifies the number.
            let base = Text("widget.health_score.header") + Text(": ") + Text("\(glance.score)")
            return glance.configured
                ? base + Text(verbatim: ". ") + Text("widget.health_score.configured")
                : base
        } else {
            return Text("widget.health_score.empty")
        }
    }

    /// Deep link the whole-tile tap opens — the in-app Insights OVERVIEW surface
    /// where the full Personal Health Score lives. The score is a composite, not
    /// a single chartable `MetricKind`, so this deliberately lands on the
    /// Insights root (`.insights(metric: nil)` → pager index 0) rather than a
    /// per-metric page (W-WIDGET-DEEPLINK).
    private static let insightsDeepLink = URL(string: InsightsLatestMeasurementDeepLink.rootURLString)
}

private extension View {
    func widgetAccessibilityLabel(_ label: Text) -> some View {
        accessibilityElement().accessibilityLabel(label)
    }
}
