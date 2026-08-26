import SwiftUI
import WidgetKit

/// **v0.8.4 WWIDGET-2 — today's-compliance widget.**
///
/// `systemSmall` + Lock-Screen `accessoryCircular`. Renders today's
/// medication adherence as a ring (the widget-safe ``WidgetRing``, visually
/// matched to the app's `HLRing`) plus an "x/y doses" label. Reads the App
/// Group snapshot the app writes — no network in the widget process. Non-
/// interactive (tapping opens the app).
struct ComplianceWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetKind.compliance, provider: ComplianceProvider()) { entry in
            ComplianceWidgetView(entry: entry)
                .containerBackground(LAColor.surface, for: .widget)
        }
        .configurationDisplayName(Text("widget.compliance.title"))
        .description(Text("widget.compliance.description"))
        .supportedFamilies([.systemSmall, .accessoryCircular])
    }
}

// MARK: - Timeline entry + provider

struct ComplianceEntry: TimelineEntry {
    let date: Date
    let compliance: WidgetSnapshot.ComplianceSummary

    /// **audit-v0162 M3** — `true` when the backing snapshot was generated on
    /// an earlier local day (or is > 24 h old), so its "today's" taken /
    /// scheduled counts can no longer be trusted (midnight rollover / no
    /// BGTask over a weekend). The view then paints a neutral "open the app"
    /// state instead of yesterday's ring as if it were today's.
    var isStale: Bool = false
}

/// Reads the App Group snapshot. Compliance only changes when the user
/// marks a dose (app-driven `reloadTimelines`) or at the day boundary, so
/// the timeline backstops with a reload at the next local midnight (the
/// "x/y today" resets) plus the app's explicit reloads for immediacy.
struct ComplianceProvider: TimelineProvider {
    private let store: WidgetSnapshotStore

    init(store: WidgetSnapshotStore = WidgetSnapshotStore()) {
        self.store = store
    }

    func placeholder(in _: Context) -> ComplianceEntry {
        ComplianceEntry(date: .now, compliance: WidgetSnapshot.placeholder.compliance)
    }

    func getSnapshot(in _: Context, completion: @escaping @Sendable (ComplianceEntry) -> Void) {
        let now = Date.now
        let snapshot = store.read() ?? .placeholder
        let stale = WidgetTimelinePolicy.isComplianceStale(generatedAt: snapshot.generatedAt, now: now)
        completion(ComplianceEntry(date: now, compliance: snapshot.compliance, isStale: stale))
    }

    func getTimeline(in _: Context, completion: @escaping @Sendable (Timeline<ComplianceEntry>) -> Void) {
        let now = Date.now
        let snapshot = store.read() ?? .placeholder
        // audit-v0162 M3 — a snapshot from a previous local day (or > 24 h old)
        // can't be shown as today's adherence; flag it so the view renders the
        // neutral "open the app" state instead of yesterday's counts.
        let stale = WidgetTimelinePolicy.isComplianceStale(generatedAt: snapshot.generatedAt, now: now)
        let entry = ComplianceEntry(date: now, compliance: snapshot.compliance, isStale: stale)
        completion(Timeline(entries: [entry], policy: .after(WidgetTimelinePolicy.complianceReload(after: now))))
    }
}

// MARK: - Views

private struct ComplianceWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ComplianceEntry

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
                Text("widget.compliance.header")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(LAColor.textSecondary)
            } icon: {
                Image(systemName: "pills.fill")
                    .foregroundStyle(LAColor.accent)
            }
            .labelStyle(.titleAndIcon)
            .frame(maxWidth: .infinity, alignment: .leading)

            if entry.isStale {
                staleBody
            } else {
                freshBody
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// **audit-v0162 M3** — neutral state for a stale snapshot: no ring, no
    /// counts (which would be yesterday's), just a prompt to open the app.
    private var staleBody: some View {
        VStack(spacing: 6) {
            Spacer(minLength: 0)
            Image(systemName: "exclamationmark.arrow.circlepath")
                .font(.title2)
                .foregroundStyle(LAColor.textSecondary)
            Text("widget.stale.open_app")
                .font(.caption)
                .foregroundStyle(LAColor.textSecondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
    }

    private var freshBody: some View {
        VStack(spacing: 8) {
            WidgetRing(
                // W-B183 coherence — the ring ARC tracks the SERVER ledger
                // adherence (`ringFraction` prefers `serverCompliancePercent`,
                // the same value the in-app card paints) and falls back to
                // today's count only when the server value is unavailable.
                progress: entry.compliance.ringFraction,
                value: ringValue,
                caption: String(localized: "widget.compliance.today")
            )

            Text(dosesLabel)
                .font(.caption)
                .foregroundStyle(LAColor.textSecondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var accessoryCircular: some View {
        // audit-v0162 M3 — a stale snapshot drives an empty gauge + em-dash
        // rather than yesterday's fraction/counts painted as today's.
        Gauge(value: entry.isStale ? 0 : entry.compliance.ringFraction) {
            Image(systemName: entry.isStale ? "exclamationmark.arrow.circlepath" : "pills.fill")
        } currentValueLabel: {
            Text(ringValue)
                .minimumScaleFactor(0.5)
        }
        .gaugeStyle(.accessoryCircular)
        .widgetAccessibilityLabel(
            entry.isStale
                ? Text("widget.stale.open_app")
                : Text("widget.compliance.header") + Text(": ") + Text(dosesLabel)
        )
    }

    /// "4/6" — taken over scheduled. Shown in the ring centre + the gauge. A
    /// stale snapshot shows an em-dash instead of out-of-date counts.
    private var ringValue: String {
        if entry.isStale { return "—" }
        return "\(entry.compliance.taken)/\(entry.compliance.scheduled)"
    }

    /// "4 von 6 Dosen" — localised "x/y doses" label.
    private var dosesLabel: String {
        String(
            format: String(localized: "widget.compliance.doses"),
            entry.compliance.taken,
            entry.compliance.scheduled
        )
    }
}

private extension View {
    func widgetAccessibilityLabel(_ label: Text) -> some View {
        accessibilityElement().accessibilityLabel(label)
    }
}
