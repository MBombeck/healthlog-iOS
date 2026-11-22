import AppIntents
import SwiftUI
import WidgetKit

/// **Next-scheduled-dose widget.**
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

    /// Whether the current dose's "Genommen"
    /// button is armed for confirm (first tap landed). When `true` the button
    /// renders "Bestätigen?"; a fresh tap on this state commits the intake.
    /// Read from the App Group pending-confirm marker at timeline-build time;
    /// a stale marker reads `false` so the button auto-reverts.
    let pendingConfirm: Bool

    /// **W-B183 coherence — the app's resolved `HLTimeFormat` raw value**
    /// carried in the snapshot, so the widget renders the dose time with the
    /// SAME clock (12h / 24h / auto) the app does. Defaults to "AUTO".
    var timeFormatRaw: String = "AUTO"

    /// `true` when the backing snapshot's `generatedAt`
    /// is older than ``WidgetTimelinePolicy/nextDoseStaleThreshold`` (the app
    /// hasn't refreshed it in a long time — e.g. no BGTask over a weekend). The
    /// view then paints the neutral "open the app" state instead of a stale
    /// dose, and `dose` is forced to `nil` so the interactive "Genommen" button
    /// is suppressed (no intake recorded against a slot that has long passed).
    var isStale: Bool = false

    /// What the last "Taken" tap on this dose did, until the app has written
    /// a newer snapshot (``WidgetDoseOutcomeStore``).
    var outcome: WidgetDoseOutcomeStore.Kind?

    /// Smart Stack ranking: high around the slot, low otherwise, zero without
    /// an open dose or once a tap saved it (``NextDoseRelevance``).
    var relevance: TimelineEntryRelevance? {
        TimelineEntryRelevance(score: NextDoseRelevance.relevance(
            for: dose?.scheduledAt,
            now: date,
            settled: outcome?.settlesDose ?? false
        ))
    }
}

/// Reads the App Group snapshot + builds a refresh timeline. The timeline
/// reloads at the dose's scheduled time (so an overdue → "now" transition
/// repaints) and on a periodic cadence as a backstop; the app also calls
/// `WidgetCenter.reloadTimelines` on every intake change for immediacy.
struct NextDoseProvider: TimelineProvider {
    private let store: WidgetSnapshotStore
    private let pendingStore: WidgetPendingConfirmStore
    private let outcomeStore: WidgetDoseOutcomeStore

    init(
        store: WidgetSnapshotStore = WidgetSnapshotStore(),
        pendingStore: WidgetPendingConfirmStore = WidgetPendingConfirmStore(),
        outcomeStore: WidgetDoseOutcomeStore = WidgetDoseOutcomeStore()
    ) {
        self.store = store
        self.pendingStore = pendingStore
        self.outcomeStore = outcomeStore
    }

    /// The tap outcome of `dose`, or `.recorded` when the confirmation push
    /// recorded it as taken elsewhere (#189 (1)).
    static func outcome(
        store: WidgetDoseOutcomeStore,
        dose: WidgetSnapshot.NextDose?,
        snapshot: WidgetSnapshot,
        now: Date
    ) -> WidgetDoseOutcomeStore.Kind? {
        if let dose, ResolvedDoseLedger().contains(
            medicationId: dose.medicationId,
            slotAt: dose.scheduledAt,
            recordedAfter: snapshot.generatedAt
        ) {
            return .recorded
        }
        return store.kind(for: dose, snapshotGeneratedAt: snapshot.generatedAt, now: now)
    }

    func placeholder(in _: Context) -> NextDoseEntry {
        NextDoseEntry(date: .now, dose: WidgetSnapshot.placeholder.nextDose, pendingConfirm: false)
    }

    func getSnapshot(in _: Context, completion: @escaping @Sendable (NextDoseEntry) -> Void) {
        let now = Date.now
        let snapshot = store.read() ?? .placeholder
        // A snapshot the app hasn't refreshed in a long time
        // (no BGTask over a weekend) must not surface a stale dose; drop it so
        // the "open the app" state renders and the action button is suppressed.
        let stale = WidgetTimelinePolicy.isNextDoseUntrusted(
            generatedAt: snapshot.generatedAt,
            scheduledAt: snapshot.nextDose?.scheduledAt,
            now: now
        )
        let dose = stale ? nil : snapshot.nextDose
        completion(NextDoseEntry(
            date: now,
            dose: dose,
            pendingConfirm: false,
            timeFormatRaw: snapshot.timeFormatRaw,
            isStale: stale,
            outcome: Self.outcome(store: outcomeStore, dose: dose, snapshot: snapshot, now: now)
        ))
    }

    func getTimeline(in _: Context, completion: @escaping @Sendable (Timeline<NextDoseEntry>) -> Void) {
        let now = Date.now
        let snapshot = store.read() ?? .placeholder
        // Suppress a stale dose (+ its live action button)
        // when the snapshot is older than the next-dose staleness cutoff.
        let stale = WidgetTimelinePolicy.isNextDoseStale(generatedAt: snapshot.generatedAt, now: now)
        let dose = stale ? nil : snapshot.nextDose
        let outcome = Self.outcome(store: outcomeStore, dose: dose, snapshot: snapshot, now: now)
        // Armed only for the slot currently surfaced — a stale or
        // different-dose marker reads as absent so the button auto-reverts.
        let armedAt = dose.flatMap { dose in
            pendingStore.armed(for: dose.medicationId, scheduledFor: dose.scheduledAt, now: now)
                ? pendingStore.read(now: now)?.armedAt
                : nil
        }
        // The revert is its own frame at the window edge, not a reload request:
        // WidgetKit does not reload on the second, but it never shows a frame early.
        // The relevance window edges are frames too, so the Smart Stack sees
        // the score change at the edge and not at the next reload.
        let frames = NextDoseRelevance.frames(
            WidgetTimelinePolicy.pendingConfirmFrames(
                now: now,
                armedAt: armedAt,
                window: WidgetPendingConfirmStore.pendingConfirmWindow
            ),
            scheduledAt: dose?.scheduledAt,
            now: now
        )
        let entries = frames.map { frame in
            // #189 (7): from the due time on, a snapshot written long before
            // it can no longer vouch for the dose; that frame shows no button.
            let untrusted = stale || WidgetTimelinePolicy.isNextDoseUntrusted(
                generatedAt: snapshot.generatedAt,
                scheduledAt: dose?.scheduledAt,
                now: frame.date
            )
            return NextDoseEntry(
                date: frame.date,
                dose: untrusted ? nil : dose,
                pendingConfirm: frame.armed,
                timeFormatRaw: snapshot.timeFormatRaw,
                isStale: untrusted,
                outcome: outcome
            )
        }
        var reload = WidgetTimelinePolicy.nextDoseReload(after: now, scheduledAt: dose?.scheduledAt)
        // A "not saved" note leaves when its window closes.
        if outcome == .notSaved, let at = outcomeStore.read()?.at {
            reload = min(reload, max(now, at.addingTimeInterval(WidgetDoseOutcomeStore.notSavedWindow)))
        }
        completion(Timeline(entries: entries, policy: .after(reload)))
    }
}

// MARK: - Views

private struct NextDoseWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode
    let entry: NextDoseEntry

    private var tint: WidgetTint {
        WidgetTint(renderingMode)
    }

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
        VStack(alignment: .leading, spacing: WidgetMetrics.stackSpacing) {
            header
            Spacer(minLength: 0)
            if entry.isStale {
                staleState
            } else if let dose = entry.dose {
                doseTitle(dose)
                if isSaved {
                    savedState
                } else {
                    takenButton(dose)
                    notSavedNote
                }
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// A tap on this dose was saved or queued: no second button for it.
    private var isSaved: Bool {
        entry.outcome == .recorded || entry.outcome == .queued
    }

    private var savedState: some View {
        Label {
            Text(entry.outcome == .queued ? "widget.next_dose.queued" : "widget.next_dose.recorded")
        } icon: {
            Image(systemName: entry.outcome == .queued ? "clock.badge.checkmark" : "checkmark.circle.fill")
                .widgetLayer(.statusSymbol, in: .nextDose)
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(entry.outcome == .queued ? LAColor.textSecondary : LAColor.success)
        .lineLimit(2)
        .minimumScaleFactor(0.8)
    }

    @ViewBuilder
    private var notSavedNote: some View {
        if entry.outcome == .notSaved {
            Text("widget.next_dose.not_saved")
                .font(.caption2)
                .foregroundStyle(LAColor.warn)
                .lineLimit(2)
        }
    }

    private var homeMedium: some View {
        HStack(spacing: WidgetMetrics.columnSpacing) {
            VStack(alignment: .leading, spacing: WidgetMetrics.stackSpacing) {
                header
                Spacer(minLength: 0)
                if entry.isStale {
                    staleState
                } else if let dose = entry.dose {
                    doseTitle(dose)
                    notSavedNote
                } else {
                    emptyState
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)

            // No interactive button while stale: `entry.dose`
            // is already `nil` in that case, so the button never renders and no
            // intake can be recorded against an out-of-date slot.
            if !entry.isStale, entry.dose != nil, isSaved {
                savedState
                    .frame(maxWidth: WidgetMetrics.actionColumnWidth)
            } else if !entry.isStale, let dose = entry.dose {
                takenButton(dose)
                    .frame(maxWidth: WidgetMetrics.actionColumnWidth)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        WidgetHeader(title: Text("widget.next_dose.header"), symbol: "pills.fill", surface: .nextDose)
    }

    private func doseTitle(_ dose: WidgetSnapshot.NextDose) -> some View {
        VStack(alignment: .leading, spacing: WidgetMetrics.lineSpacing) {
            // Redact the PHI med name on a locked Home-screen
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

    /// The two-step "Genommen" affordance,
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
                Text(armed ? "la.med.action.taken.confirm" : "med.dose.action.take")
            } icon: {
                Image(systemName: armed ? "checkmark.circle" : "checkmark")
            }
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            // Was `.tint(LAColor.accent) + .buttonStyle(.borderedProminent)`,
            // which rendered white-on-white in dark mode. Now the shared dark-pill
            // (explicit fill/text/border, honouring the armed two-state); the
            // outlined variant where the system drops the hues.
            .widgetTakenPill(pendingConfirm: armed, tint: tint)
        }
        .buttonStyle(.plain)
        .widgetLayer(.actionButton, in: .nextDose)
        .accessibilityLabel(Text(armed ? "la.med.action.taken.confirm" : "med.dose.action.take"))
    }

    private var emptyState: some View {
        Text("widget.next_dose.empty")
            .font(.subheadline)
            .foregroundStyle(LAColor.textSecondary)
            .lineLimit(2)
    }

    /// Shown when the snapshot is too old to trust (the
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
        VStack(alignment: .leading, spacing: WidgetMetrics.lineSpacing) {
            if entry.isStale {
                // Stale snapshot: prompt to open the app rather
                // than paint an out-of-date dose as if it were still due.
                Label {
                    Text("widget.stale.open_app")
                } icon: {
                    Image(systemName: "exclamationmark.arrow.circlepath")
                        .widgetLayer(.statusSymbol, in: .nextDose)
                }
                .font(.headline)
            } else if let dose = entry.dose {
                Label {
                    Text(dose.medicationName).lineLimit(1)
                } icon: {
                    Image(systemName: "pills.fill")
                        .widgetLayer(.statusSymbol, in: .nextDose)
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
                        .widgetLayer(.statusSymbol, in: .nextDose)
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
                .widgetLayer(.statusSymbol, in: .nextDose)
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
            Text("\(Text("widget.next_dose.header")): \(Text(dose.medicationName))")
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
