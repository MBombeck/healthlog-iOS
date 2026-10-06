import Foundation

/// #115 · 1.3 — when the Home compliance ring must re-read the server.
///
/// The ring renders `GET /api/dashboard/summary` → `compliance` verbatim. It
/// used to overlay a count derived on the device from today's intakes
/// (`ComplianceReconciler`, removed), partly so a dose marked on Home showed up
/// at once. Now the summary is re-read instead: whenever the number of
/// resolved (taken / skipped) doses in the loaded today list changes after
/// the list was already loaded, one forced summary refresh runs.
///
/// The first load (not loaded → loaded) is deliberately NOT a trigger, so the
/// launch path gains no request. A change that arrives from the server itself
/// (another device marked a dose) also re-reads, which is the same answer.
struct DashboardIntakeSignature: Equatable {
    /// `MedicationsStore.hasLoadedMedications` at the time of the read.
    let loaded: Bool
    /// Today's doses already taken or skipped.
    let resolved: Int

    init(loaded: Bool, resolved: Int) {
        self.loaded = loaded
        self.resolved = resolved
    }

    @MainActor
    init(_ store: MedicationsStore) {
        self.init(
            loaded: store.hasLoadedMedications,
            resolved: store.todayIntakes.count(where: { $0.status == .taken || $0.status == .skipped })
        )
    }

    /// Refresh only for a change within an already-loaded list.
    static func shouldRefreshSummary(from old: Self, to new: Self) -> Bool {
        old.loaded && new.loaded && old.resolved != new.resolved
    }
}
