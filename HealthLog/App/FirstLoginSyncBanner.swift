import SwiftUI

/// v0.14.8 W2-SYNCUX — the first-login sync indicator (AUDIT-QOL-UX §4 spec).
///
/// Reuses the two existing primitives ONLY — `HLSyncBanner` (the calm
/// `AdoptUploadIndicator` strip) for the chrome and the `SyncStatusCaption`
/// language (`sync.status.preparing` / `sync.status.syncing`) for the copy.
///
/// **Lifecycle (one-shot per install — `hl.sync.firstLoginBannerCompleted`):**
/// 1. `pending` — a short grace beat (450 ms). Warm sessions hydrate the
///    summary from the persistent SWR cache in <100 ms, so the window has
///    already closed and the banner resolves straight to `finished` without
///    ever painting (no cold-launch flash).
/// 2. `visible` — the genuine first-login window: server session, no
///    dashboard summary, no sync handshake yet, never completed before.
///    Spinner + "Deine Daten werden vorbereitet…" → "Wird synchronisiert…"
///    once a load is actually in flight. The HK initial backfill stays
///    indeterminate by design — no invented percent bar (spec §4.5).
/// 3. `done` — the first summary/handshake landed: short "Synchronisiert"
///    checkmark beat (~1.5 s, mirrors `AdoptUploadIndicator.done`).
/// 4. `finished` — gone for good. The completion flag is a UI-pref in
///    UserDefaults (the audit's "Bedingung greift nur, solange noch nie ein
///    Handshake gelandet ist" needs persistence — `lastHandshakeAt` is
///    in-memory and the summary SWR cache key is day-anchored, so without
///    the flag every new-day cold launch would re-open the window). From
///    here on the quiet `HLSyncStatusFooter` caption owns the sync story.
///
/// Standalone sessions (`AuthStore.Phase.standalone`) never open the window —
/// there is no server handshake to wait for (spec §4.6). Reduce-Motion
/// suppresses the slide/spring entirely (cross-dissolve via `nil` animation).
struct FirstLoginSyncBanner: View {
    /// UserDefaults key for the one-shot completion flag (UI-pref — allowed
    /// in UserDefaults per PROJECT_GUIDE.md). Purged by the `-uitest-skip-bootstrap`
    /// seam so walkthrough tests exercise a true first login every run.
    static let completedDefaultsKey = "hl.sync.firstLoginBannerCompleted"

    @Environment(AuthStore.self) private var authStore
    @Environment(SyncStateStore.self) private var syncState
    @Environment(DashboardStore.self) private var dashboardStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Phase: Equatable {
        case pending
        case visible
        case done
        case finished
    }

    @State private var phase: Phase = .pending
    @AppStorage(Self.completedDefaultsKey) private var hasCompletedFirstSync = false

    /// The first-login window — the audit-spec predicate
    /// (`lastHandshakeAt == nil && summary == nil`, the same family that
    /// feeds the Dashboard caption's `firstLoginPreparing`) plus the
    /// persisted one-shot guard. NOTE: deliberately NOT gated on
    /// `settings.profile` — the profile already loads during onboarding
    /// (`RootView.loadProfileOnAuthenticationIfNeeded` fires on the auth
    /// transition, before this shell mounts), so a profile guard would
    /// suppress the banner on the standard first-login path.
    private var windowOpen: Bool {
        guard case .authenticated = authStore.phase else { return false }
        return !hasCompletedFirstSync
            && dashboardStore.summary == nil
            && syncState.lastHandshakeAt == nil
    }

    /// `true` once the first sync actually produced data — distinguishes a
    /// data-driven window close (mark completed) from e.g. a logout flip.
    private var firstSyncLanded: Bool {
        dashboardStore.summary != nil || syncState.lastHandshakeAt != nil
    }

    /// `true` once any of the first-load fetches is actually in flight —
    /// flips the copy from "preparing" to "syncing".
    private var isActivelySyncing: Bool {
        syncState.isLoading || dashboardStore.isLoading
    }

    /// b177 W-SYNCPROGRESS — the banner copy. While actively syncing WITH a
    /// known outstanding quantity (outbox backlog + in-flight revalidations)
    /// the strip shows the honest count ("Wird synchronisiert… N ausstehend",
    /// same key as the footer caption). Still no invented percent bar — the
    /// HK initial backfill stays indeterminate by design (spec §4.5).
    private var bannerText: String {
        guard isActivelySyncing else {
            return String(localized: "sync.status.preparing")
        }
        let pending = syncState.pendingSyncCount
        guard pending > 0 else {
            return String(localized: "sync.status.syncing")
        }
        return String(localized: "sync.status.syncingCount \(pending)")
    }

    var body: some View {
        // NOTE: deliberately a `VStack`, NOT a `Group` — `Group` distributes
        // its modifiers onto the resolved child, and in the `pending`/
        // `finished` arms that child is `EmptyView`, whose `.task`/`.onChange`
        // never fire. The unary `VStack` container keeps the lifecycle
        // modifiers alive while rendering zero points of height.
        VStack(spacing: 0) {
            switch phase {
            case .pending, .finished:
                EmptyView()
            case .visible:
                HLSyncBanner(
                    text: bannerText,
                    showsSpinner: true
                )
                .accessibilityIdentifier("sync.firstLogin.banner")
            case .done:
                HLSyncBanner(
                    text: String(localized: "sync.banner.done"),
                    symbol: "checkmark.circle.fill"
                )
                .accessibilityIdentifier("sync.firstLogin.done")
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.9), value: phase)
        .task {
            // Grace beat — see lifecycle step 1. Sessions whose window was
            // never open (flag set / warm cache) resolve to `finished` here
            // without ever painting. A GENUINE first login whose sync
            // completed within the grace (fast network) skips the spinner
            // but still gets the short done-flash — the user asked for
            // visible first-sync feedback, and "it was so fast you only see
            // the checkmark" is the honest version of that.
            let windowWasOpenAtMount = windowOpen
            try? await Task.sleep(for: .milliseconds(450))
            guard phase == .pending else { return }
            if windowOpen {
                phase = .visible
            } else if windowWasOpenAtMount, firstSyncLanded {
                showDoneThenFinish()
            } else {
                markCompletedIfDataLanded()
                phase = .finished
            }
        }
        .onChange(of: windowOpen) { _, open in
            guard !open else { return }
            switch phase {
            case .visible:
                showDoneThenFinish()
            case .pending:
                // Window closed during the grace beat — leave `pending`;
                // the `.task` arm above resolves it at grace end (and still
                // grants the done-flash for a genuine first login).
                break
            case .done, .finished:
                break
            }
        }
    }

    /// Persists the one-shot flag, but only when the close was data-driven
    /// (summary or handshake landed) — a logout-driven close must keep the
    /// flag clear so the next account's genuine first sync still surfaces.
    private func markCompletedIfDataLanded() {
        if firstSyncLanded {
            hasCompletedFirstSync = true
        }
    }

    /// The settled checkmark beat (~1.5 s) → gone for good.
    private func showDoneThenFinish() {
        markCompletedIfDataLanded()
        phase = .done
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if phase == .done { phase = .finished }
        }
    }
}
