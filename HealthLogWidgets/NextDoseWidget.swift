import AppIntents
import SwiftUI
import WidgetKit

/// **v0.8.4 WWIDGET-2 — next-scheduled-dose widget.**
///
/// Home-screen (`systemSmall` / `systemMedium`) + Lock-Screen
/// (`accessoryRectangular` / `accessoryCircular`). Paints the soonest due
/// (or currently-overdue) medication + its time from the App Group
/// snapshot the app writes — no network in the widget process. On the
/// Home-screen sizes it carries an inline interactive "Genommen"
/// `Button(intent:)` that fires the already-shipped
/// ``MarkMedicationTakenIntent`` (server-first, runs in the extension
/// process via the shared Keychain token). The Lock-Screen accessory
/// variants are non-interactive glanceable per the accessory contract.
struct NextDoseWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetKind.nextDose, provider: NextDoseProvider()) { entry in
            NextDoseWidgetView(entry: entry)
                .containerBackground(LAColor.surface, for: .widget)
        }
        .configurationDisplayName(Text("widget.next_dose.title"))
        .description(Text("widget.next_dose.description"))
        .supportedFamilies([
            .systemSmall,
            .systemMedium,
            .accessoryRectangular,
            .accessoryCircular
        ])
    }
}

// MARK: - Timeline entry + provider

/// One frame of the next-dose timeline. `Sendable` (value type of
/// `Sendable` members) so it crosses the nonisolated `TimelineProvider`
/// boundary cleanly under Swift 6 strict concurrency.
struct NextDoseEntry: TimelineEntry {
    let date: Date
    let dose: WidgetSnapshot.NextDose?

    /// **v0.10.0 W-Widget-2Tap** — whether the current dose's "Genommen"
    /// button is armed for confirm (first tap landed). When `true` the button
    /// renders "Bestätigen?"; a fresh tap on this state commits the intake.
    /// Read from the App Group pending-confirm marker at timeline-build time;
    /// a stale marker reads `false` so the button auto-reverts.
    let pendingConfirm: Bool

    /// **W-B183 coherence — the app's resolved `HLTimeFormat` raw value**
    /// carried in the snapshot, so the widget renders the dose time with the
    /// SAME clock (12h / 24h / auto) the app does. Defaults to "AUTO".
    var timeFormatRaw: String = "AUTO"

    /// **audit-v0162 M3** — `true` when the backing snapshot's `generatedAt`
    /// is older than ``WidgetTimelinePolicy/nextDoseStaleThreshold`` (the app
    /// hasn't refreshed it in a long time — e.g. no BGTask over a weekend). The
    /// view then paints the neutral "open the app" state instead of a stale
    /// dose, and `dose` is forced to `nil` so the interactive "Genommen" button
    /// is suppressed (no intake recorded against a slot that has long passed).
    var isStale: Bool = false
}

/// Reads the App Group snapshot + builds a refresh timeline. The timeline
/// reloads at the dose's scheduled time (so an overdue → "now" transition
/// repaints) and on a periodic cadence as a backstop; the app also calls
/// `WidgetCenter.reloadTimelines` on every intake change for immediacy.
struct NextDoseProvider: TimelineProvider {
    private let store: WidgetSnapshotStore
    private let pendingStore: WidgetPendingConfirmStore

    init(
        store: WidgetSnapshotStore = WidgetSnapshotStore(),
        pendingStore: WidgetPendingConfirmStore = WidgetPendingConfirmStore()
    ) {
        self.store = store
        self.pendingStore = pendingStore
    }

    func placeholder(in _: Context) -> NextDoseEntry {
        NextDoseEntry(date: .now, dose: WidgetSnapshot.placeholder.nextDose, pendingConfirm: false)
    }

    func getSnapshot(in _: Context, completion: @escaping @Sendable (NextDoseEntry) -> Void) {
        let now = Date.now
        let snapshot = store.read() ?? .placeholder
        // audit-v0162 M3 — a snapshot the app hasn't refreshed in a long time
        // (no BGTask over a weekend) must not surface a stale dose; drop it so
        // the "open the app" state renders and the action button is suppressed.
        let stale = WidgetTimelinePolicy.isNextDoseStale(generatedAt: snapshot.generatedAt, now: now)
        completion(NextDoseEntry(
            date: now,
            dose: stale ? nil : snapshot.nextDose,
            pendingConfirm: false,
            timeFormatRaw: snapshot.timeFormatRaw,
            isStale: stale
        ))
    }

    func getTimeline(in _: Context, completion: @escaping @Sendable (Timeline<NextDoseEntry>) -> Void) {
        let now = Date.now
        let snapshot = store.read() ?? .placeholder
        // audit-v0162 M3 — suppress a stale dose (+ its live action button)
        // when the snapshot is older than the next-dose staleness cutoff.
        let stale = WidgetTimelinePolicy.isNextDoseStale(generatedAt: snapshot.generatedAt, now: now)
        let dose = stale ? nil : snapshot.nextDose
        // Armed only for the dose currently surfaced — a stale or
        // different-dose marker reads `false` so the button auto-reverts.
        let pending = dose.map { pendingStore.armed(for: $0.medicationId, now: now) } ?? false
        let entry = NextDoseEntry(
            date: now,
            dose: dose,
            pendingConfirm: pending,
            timeFormatRaw: snapshot.timeFormatRaw,
            isStale: stale
        )
        // When armed, reload again at the window edge so the button reverts to
        // "Genommen" if the second tap never lands; else the normal cadence.
        let armReload = now.addingTimeInterval(WidgetPendingConfirmStore.pendingConfirmWindow)
        let baseReload = WidgetTimelinePolicy.nextDoseReload(after: now, scheduledAt: dose?.scheduledAt)
        let reload = pending ? min(armReload, baseReload) : baseReload
        completion(Timeline(entries: [entry], policy: .after(reload)))
    }
}

// MARK: - Views

private struct NextDoseWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: NextDoseEntry

    var body: some View {
        switch family {
        case .accessoryCircular:
            accessoryCircular
        case .accessoryRectangular:
            accessoryRectangular
        case .systemMedium:
            homeMedium
        default:
            homeSmall
        }
    }

    // MARK: Home-screen sizes (interactive)

    private var homeSmall: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            Spacer(minLength: 0)
            if entry.isStale {
                staleState
            } else if let dose = entry.dose {
                doseTitle(dose)
                takenButton(dose)
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var homeMedium: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                header
                Spacer(minLength: 0)
                if entry.isStale {
                    staleState
                } else if let dose = entry.dose {
                    doseTitle(dose)
                } else {
                    emptyState
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)

            // audit-v0162 M3 — no interactive button while stale: `entry.dose`
            // is already `nil` in that case, so the button never renders and no
            // intake can be recorded against an out-of-date slot.
            if !entry.isStale, let dose = entry.dose {
                takenButton(dose)
                    .frame(maxWidth: 130)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        Label {
            Text("widget.next_dose.header")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(LAColor.textSecondary)
        } icon: {
            Image(systemName: "pills.fill")
                .foregroundStyle(LAColor.accent)
        }
        .labelStyle(.titleAndIcon)
    }

    private func doseTitle(_ dose: WidgetSnapshot.NextDose) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            // W-RECONCILE H1 — redact the PHI med name on a locked Home-screen
            // widget, consistent with the lock-screen accessory below.
            Text(dose.medicationName)
                .font(.headline)
                .foregroundStyle(LAColor.text)
                .lineLimit(1)
                .privacySensitive()
            Text(dueLine(dose))
                .font(.caption)
                .foregroundStyle(LAColor.textSecondary)
                .lineLimit(1)
        }
    }

    /// **v0.10.0 W-Widget-2Tap** — the two-step "Genommen" affordance,
    /// mirroring the Live Activity's `TakenButton`. When not armed it reads
    /// "Genommen"; the first tap arms the App Group pending-confirm marker and
    /// reloads, re-rendering this as "Bestätigen?" — only a fresh tap on that
    /// armed state records the intake. One accidental tap never records a dose.
    private func takenButton(_ dose: WidgetSnapshot.NextDose) -> some View {
        let armed = entry.pendingConfirm
        return Button(
            intent: MarkNextDoseFromWidgetIntent(
                medicationId: dose.medicationId,
                medicationName: dose.medicationName,
                scheduledForEpoch: dose.scheduledAt.timeIntervalSince1970
            )
        ) {
            Label {
                Text(armed ? "la.med.action.taken.confirm" : "widget.next_dose.taken")
            } icon: {
                Image(systemName: armed ? "checkmark.circle" : "checkmark")
            }
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            // b146 — was `.tint(LAColor.accent) + .buttonStyle(.borderedProminent)`,
            // which rendered white-on-white in dark mode. Now the shared dark-pill
            // (explicit fill/text/border, honouring the armed two-state).
            .laMedTakenPill(pendingConfirm: armed)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(armed ? "la.med.action.taken.confirm" : "widget.next_dose.taken"))
    }

    private var emptyState: some View {
        Text("widget.next_dose.empty")
            .font(.subheadline)
            .foregroundStyle(LAColor.textSecondary)
            .lineLimit(2)
    }

    /// **audit-v0162 M3** — shown when the snapshot is too old to trust (the
    /// app hasn't refreshed the widget in a long time). Neutral prompt to open
    /// the app; carries no dose, no time, and no action button.
    private var staleState: some View {
        Text("widget.stale.open_app")
            .font(.subheadline)
            .foregroundStyle(LAColor.textSecondary)
            .lineLimit(2)
    }

    // MARK: Lock-Screen accessories (glanceable, non-interactive)

    private var accessoryRectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            if entry.isStale {
                // audit-v0162 M3 — stale snapshot: prompt to open the app rather
                // than paint an out-of-date dose as if it were still due.
                Label {
                    Text("widget.stale.open_app")
                } icon: {
                    Image(systemName: "exclamationmark.arrow.circlepath")
                }
                .font(.headline)
            } else if let dose = entry.dose {
                Label {
                    Text(dose.medicationName).lineLimit(1)
                } icon: {
                    Image(systemName: "pills.fill")
                }
                .font(.headline)
                // Lock-screen accessory: the medication name is PHI — redact it
                // when the device is locked (QA-b198 Sec-L-3).
                .privacySensitive()
                Text(dueLine(dose))
                    .font(.caption)
                    .lineLimit(1)
            } else {
                Label {
                    Text("widget.next_dose.empty")
                } icon: {
                    Image(systemName: "checkmark.circle")
                }
                .font(.headline)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var accessoryCircular: some View {
        ZStack {
            AccessoryWidgetBackground()
            Image(systemName: circularSymbol)
                .font(.title2)
        }
        .widgetAccessibilityLabel(accessoryLabel)
    }

    private var circularSymbol: String {
        if entry.isStale { return "exclamationmark.arrow.circlepath" }
        return entry.dose == nil ? "checkmark.circle" : "pills.fill"
    }

    private var accessoryLabel: Text {
        if entry.isStale {
            Text("widget.stale.open_app")
        } else if let dose = entry.dose {
            Text("widget.next_dose.header") + Text(": ") + Text(dose.medicationName)
        } else {
            Text("widget.next_dose.empty")
        }
    }

    /// "fällig um HH:mm" — localised template with the user's short time.
    ///
    /// W-B183 coherence — route the clock through the canonical ``HLTimeFormat``
    /// (resolved from the snapshot's carried preference) instead of a raw
    /// `.formatted(...)` so the widget shows the SAME 12h/24h/auto string the
    /// app does.
    private func dueLine(_ dose: WidgetSnapshot.NextDose) -> String {
        let format = HLTimeFormat(rawValue: entry.timeFormatRaw) ?? .auto
        let time = format.formatTime(dose.scheduledAt)
        return String(
            format: String(localized: "widget.next_dose.due_at"),
            time
        )
    }
}

private extension View {
    /// Apply an accessibility label without leaking the modifier import
    /// noise into the call site.
    func widgetAccessibilityLabel(_ label: Text) -> some View {
        accessibilityElement().accessibilityLabel(label)
    }
}
