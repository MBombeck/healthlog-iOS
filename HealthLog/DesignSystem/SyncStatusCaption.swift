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
/// 3. **Settled** — the last handshake timestamp formatted in the user's locale
///    short time style: "Zuletzt synchronisiert HH:MM". Self-suppresses entirely
///    until the first handshake lands (no timestamp → render nothing).
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

    var body: some View {
        let resolved = Self.resolve(
            firstLoginPreparing: firstLoginPreparing,
            phase: syncState.phase,
            isInFlight: screenLoading || syncState.isLoading,
            activeSyncCount: syncState.pendingSyncCount,
            queuedWriteCount: syncState.pendingOutboxCount,
            showsDrainConfirmation: syncState.showsDrainConfirmation,
            lastHandshakeAt: syncState.lastHandshakeAt
        )
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
    /// queued) is additionally gated on `lastHandshakeAt != nil`, so standalone
    /// installs and pre-first-handshake sessions render exactly what they did
    /// before b177 — nothing (or the unchanged preparing/syncing lines).
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
        lastHandshakeAt: Date?
    ) -> CaptionState {
        if firstLoginPreparing { return .preparing }
        if phase == .syncing || isInFlight { return .syncing(pending: activeSyncCount) }
        if phase == .done || showsDrainConfirmation, lastHandshakeAt != nil { return .transmitted }
        if queuedWriteCount > 0, lastHandshakeAt != nil { return .queued(queuedWriteCount) }
        if let at = lastHandshakeAt { return .lastSynced(at) }
        return .hidden
    }

    /// The settled timestamp string in the user's locale short time style.
    private func lastSyncedText(_ at: Date) -> String {
        let time = at.formatted(date: .omitted, time: .shortened)
        return String(localized: "sync.status.lastSynced \(time)")
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
