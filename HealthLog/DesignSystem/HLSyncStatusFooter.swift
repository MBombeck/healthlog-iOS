import SwiftUI

/// v0.14.8 W2-SYNCUX — the **one shared sync-status footer** every refreshable
/// screen mounts at the end of its scroll content. Wraps the canonical
/// `SyncStatusCaption` (Dashboard/Insights v0.14.1, operator-approved: "nett,
/// nicht überfrachtet") with its standard placement chrome so the rollout
/// across ~16 screens cannot drift: same caption, same `HLSpace.sm` breathing
/// gap, same centered `HLText.tertiary` rhythm everywhere.
///
/// **Usage — `ScrollView`-based screens** (Dashboard, Insights pages, Meds,
/// Mood-Analyse, Achievements, Whoop/Withings, `HLSettingsPage` …): append as
/// the LAST child of the scrolled `VStack`:
///
/// ```swift
/// ScrollView {
///     VStack(spacing: HLSpace.lg) {
///         content
///         HLSyncStatusFooter(screenLoading: store.isLoading)
///     }
/// }
/// .refreshable { await store.load() }
/// ```
///
/// **Usage — `List`/`Form`-based screens** (Workouts, Messwerte, Passkeys,
/// Settings-Hub …): append an empty `Section` whose *footer* hosts the view —
/// section footers collapse to zero height when the caption self-suppresses,
/// so the hidden state never leaves a phantom 44 pt row behind:
///
/// ```swift
/// List {
///     rows
///     Section {} footer: { HLSyncStatusFooter(screenLoading: store.isLoading) }
/// }
/// .refreshable { await store.load() }
/// ```
///
/// **Self-suppression** is inherited from `SyncStatusCaption`: until the first
/// sync handshake lands (`SyncStateStore.lastHandshakeAt == nil`) and nothing
/// is in flight, the footer renders nothing — standalone installs and screens
/// without server data therefore stay byte-identical.
///
/// **b178 W-SYNCVIS:** visibility is now driven by `SyncStateStore.phase`
/// (`.syncing` held ≥ 600 ms, `.done` confirmation for 1.5 s — also on
/// read-only pulls), so the footer is perceivable on fast networks too. The
/// caption reads the phase from the environment store; call sites are
/// unchanged.
struct HLSyncStatusFooter: View {
    /// The screen's own in-flight flag (e.g. `store.isLoading`), OR'd inside
    /// the caption with `SyncStateStore.isLoading` so the footer reads
    /// "Wird synchronisiert…" during either a data refresh or the handshake.
    var screenLoading: Bool = false
    /// `true` only on a fresh session where nothing has loaded yet — drives
    /// the "Deine Daten werden vorbereitet…" one-shot hint (Dashboard +
    /// Insights root pass their existing first-login predicate; every other
    /// screen keeps the default `false`).
    var firstLoginPreparing: Bool = false

    var body: some View {
        SyncStatusCaption(
            screenLoading: screenLoading,
            firstLoginPreparing: firstLoginPreparing
        )
        .padding(.top, HLSpace.sm)
    }
}
