import SwiftUI

/// v0.14.1 — the **discreet last-synced status line** at the bottom of the
/// scroll content. Operator brief: "nett, nicht überfrachtet, nicht zu
/// plakativ" — so this is intentionally the quietest possible affordance: one
/// centered `HLText.tertiary` caption, NO badge, NO spinner, NO chrome. The
/// only motion in the sync story stays the native pull-to-refresh control
/// above it.
///
/// v0.14.8 W2-SYNCUX — promoted from `Screens/Dashboard/` into the
/// DesignSystem and rolled out to every refreshable screen via the shared
/// `HLSyncStatusFooter` wrapper. New call sites mount the wrapper, not this
/// view directly.
///
/// **Three states (most-specific first):**
/// 1. **First-login preparing** — a fresh session where nothing has loaded yet
///    (`firstLoginPreparing`): "Deine Daten werden vorbereitet…". Disappears the
///    moment real data arrives (the call site stops passing `true`).
/// 2. **In flight** — a refresh / handshake is running (`SyncStateStore.isLoading`
///    or the screen's own loading flag): "Wird synchronisiert…".
/// 3. **Settled** — the last sync (`SyncStateStore.lastSync`: handshake, outbox
///    drain or accepted Apple Health upload) in the user's locale short time
///    style: "Zuletzt synchronisiert HH:MM". Self-suppresses entirely until
///    something has synced (no timestamp → render nothing).
///
/// U1 (#16) — this line is now the *secondary* sync surface. The live
/// feedback sits at the top of the Dashboard (`HLSyncActivityGlyph`, the
/// attention glyph and `DashboardSyncStatusPanel`); all of them read the same
/// store, so the footer and the header cannot disagree.
struct SyncStatusCaption: View {
    @Environment(SyncStateStore.self) private var syncState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The screen's own in-flight flag (e.g. `DashboardStore.isLoading`), OR'd
    /// with the sync store's so the caption reads "Wird synchronisiert…" during
    /// either a data refresh or the sync handshake.
    var screenLoading: Bool = false
    /// `true` only on a fresh session where nothing has loaded yet
    /// (`settings.profile == nil && store.summary == nil`). Drives the
    /// "Deine Daten werden vorbereitet…" one-shot hint.
    var firstLoginPreparing: Bool = false
    /// 1.4 decision 3 — every screen but Today shows the line only while a
    /// real state holds: the last sync failed or is more than a day old, or
    /// writes wait for a connection. No settled time, no in-flight beat.
    var realStateOnly: Bool = false

    var body: some View {
        if realStateOnly {
            // "Stale" and "waiting" depend on the clock, so the state is
            // re-read once a minute rather than only on store changes.
            TimelineView(.everyMinute) { context in
                caption(for: Self.resolveRealStateOnly(
                    firstLoginPreparing: firstLoginPreparing,
                    attention: syncState.attention(now: context.date),
                    lastSyncAt: syncState.lastSync?.at
                ))
            }
        } else {
            caption(for: Self.resolve(
                firstLoginPreparing: firstLoginPreparing,
                phase: syncState.phase,
                isInFlight: screenLoading || syncState.isLoading,
                activeSyncCount: syncState.pendingSyncCount,
                queuedWriteCount: syncState.pendingOutboxCount,
                showsDrainConfirmation: syncState.showsDrainConfirmation,
                lastSyncAt: syncState.lastSync?.at
            ))
        }
    }

    private func caption(for resolved: CaptionState) -> some View {
        Group {
            switch resolved {
            case .preparing:
                caption("sync.status.preparing", identifier: "sync.status.preparing")
            case .syncing(pending: 0):
                caption("sync.status.syncing", identifier: "sync.status.syncing")
            case let .syncing(pending):
                // b177 W-SYNCPROGRESS — the WHOOP-style quantity: counts down
                // live as the fan-out finishes / the outbox drains. Numeric
                // digit roll is reduce-motion-gated; the layout/chrome is
                // byte-identical to the plain "Wird synchronisiert…" line.
                countingText(
                    String(localized: "sync.status.syncingCount \(pending)"),
                    count: pending,
                    identifier: "sync.status.syncingCount"
                )
            case let .queued(count):
                countingText(
                    String(localized: "sync.status.queued \(count)"),
                    count: count,
                    identifier: "sync.status.queued"
                )
            case .transmitted:
                caption("sync.status.transmitted", identifier: "sync.status.transmitted")
            case let .lastSynced(at):
                Text(lastSyncedText(at))
                    .font(.hlCaption)
                    .foregroundStyle(HLText.tertiary)
                    .accessibilityIdentifier("sync.status.lastSynced")
            case let .failedSince(at):
                stateLine(String(localized: "sync.status.failedSince \(syncTimeText(at))"))
            case let .staleSince(at):
                stateLine(String(localized: "sync.status.staleSince \(syncTimeText(at))"))
            case let .attention(attention):
                Text(SyncActivityCopy.attention(attention, now: .now))
                    .font(.hlCaption)
                    .foregroundStyle(HLText.tertiary)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("sync.status.attention")
            case .hidden:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        // b178 W-SYNCVIS — phase transitions crossfade quietly (monochrome,
        // no chrome); under Reduce Motion the caption switches hard-cut.
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: resolved)
    }

    /// The pure caption-state decision, extracted so it is unit-testable without
    /// a SwiftUI host. Most-specific arm first: first-login preparing wins, then
    /// an in-flight sync (with its honest outstanding-work count), then the
    /// short post-drain "Daten übermittelt ✓" beat, then a settled-but-queued
    /// backlog, then the settled timestamp, else nothing.
    ///
    /// **Self-suppression contract is unchanged:** every new arm (transmitted /
    /// queued) is additionally gated on `lastSyncAt != nil`, so standalone
    /// installs and never-synced sessions render exactly what they did
    /// before b177 — nothing (or the unchanged preparing/syncing lines).
    ///
    /// U1 (#16) — `lastSyncAt` is `SyncStateStore.lastSync`, no longer the
    /// handshake alone: an Apple Health upload the server accepted in the
    /// background counts, so the line is no longer older than the data.
    enum CaptionState: Equatable {
        case preparing
        /// In flight. `pending` is the live aggregate (outbox backlog +
        /// active SWR revalidations); `0` renders the plain syncing line.
        case syncing(pending: Int)
        /// Settled, but queued writes wait for replay (offline backlog).
        case queued(Int)
        /// The outbox just drained — short "Daten übermittelt ✓" beat.
        case transmitted
        case lastSynced(Date)
        /// 1.4 — writes that wait or were given up on, as one calm sentence.
        case attention(SyncAttention)
        /// 1.4 B4 — outside Today: a failed or day-old sync, said as that
        /// state with the time of the last good one, so it never reads as the
        /// plain "Zuletzt synchronisiert" line that Today alone shows.
        case failedSince(Date)
        case staleSince(Date)
        case hidden
    }

    /// b178 W-SYNCVIS adds the handshake `phase`: `.syncing` forces the
    /// in-flight line even after the GET landed (minimum visibility beat),
    /// `.done` shows the "Daten übermittelt ✓" confirmation ALSO for
    /// read-only handshakes — the old drain-confirmation arm stays as the
    /// outbox-driven sibling trigger.
    nonisolated static func resolve(
        firstLoginPreparing: Bool,
        phase: SyncPhase = .idle,
        isInFlight: Bool,
        activeSyncCount: Int = 0,
        queuedWriteCount: Int = 0,
        showsDrainConfirmation: Bool = false,
        lastSyncAt: Date?
    ) -> CaptionState {
        if firstLoginPreparing { return .preparing }
        if phase == .syncing || isInFlight { return .syncing(pending: activeSyncCount) }
        if phase == .done || showsDrainConfirmation, lastSyncAt != nil { return .transmitted }
        if queuedWriteCount > 0, lastSyncAt != nil { return .queued(queuedWriteCount) }
        if let at = lastSyncAt { return .lastSynced(at) }
        return .hidden
    }

    /// **1.4 decision 3** — the footer outside Today. A failed or day-old
    /// sync names the time of the last one, writes waiting for a connection or
    /// given up on say so, and a healthy state shows nothing at all.
    ///
    /// 1.4 B4 — the failed and the day-old sync say what they are
    /// ("Synchronisierung fehlgeschlagen, zuletzt erfolgreich 13:28", "Seit
    /// 21. Okt., 13:28 nicht synchronisiert"). Rendered as "Zuletzt
    /// synchronisiert 13:28" they looked like Today's settled line, the one
    /// rule 6 keeps on Today.
    nonisolated static func resolveRealStateOnly(
        firstLoginPreparing: Bool,
        attention: SyncAttention?,
        lastSyncAt: Date?
    ) -> CaptionState {
        if firstLoginPreparing { return .preparing }
        guard let attention else { return .hidden }
        switch attention {
        case .failed:
            return lastSyncAt.map(CaptionState.failedSince) ?? .attention(attention)
        case .stale:
            return lastSyncAt.map(CaptionState.staleSince) ?? .attention(attention)
        case .queued, .failedWrites:
            return .attention(attention)
        }
    }

    /// The settled timestamp in the user's locale: the time alone today, the
    /// day and the time before today, so a day-old sync never reads as fresh.
    private func lastSyncedText(_ at: Date) -> String {
        String(localized: "sync.status.lastSynced \(syncTimeText(at))")
    }

    private func syncTimeText(_ at: Date) -> String {
        Calendar.current.isDateInToday(at)
            ? at.formatted(date: .omitted, time: .shortened)
            : at.formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }

    private func stateLine(_ text: String) -> some View {
        Text(text)
            .font(.hlCaption)
            .foregroundStyle(HLText.tertiary)
            .multilineTextAlignment(.center)
            .accessibilityIdentifier("sync.status.attention")
    }

    /// W2-SYNCUX — the in-flight states now carry stable accessibility
    /// identifiers too (the settled state always had one), so walkthrough
    /// tests + AX can address every caption state.
    private func caption(_ key: LocalizedStringKey, identifier: String) -> some View {
        Text(key)
            .font(.hlCaption)
            .foregroundStyle(HLText.tertiary)
            .accessibilityIdentifier(identifier)
    }

    /// b177 W-SYNCPROGRESS — a caption whose embedded number counts down
    /// live. Same font/tint/placement as every other caption arm (monochrome,
    /// `HLText.tertiary`); the only addition is the numeric digit-roll
    /// content transition, suppressed entirely under Reduce Motion.
    private func countingText(_ text: String, count: Int, identifier: String) -> some View {
        Text(text)
            .font(.hlCaption)
            .monospacedDigit()
            .foregroundStyle(HLText.tertiary)
            .contentTransition(reduceMotion ? .identity : .numericText(countsDown: true))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: count)
            .accessibilityIdentifier(identifier)
    }
}
