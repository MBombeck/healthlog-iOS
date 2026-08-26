import SwiftUI

/// **v0.5.4.3 HP-6 — Dashboard ↔ MedicationsStore compliance reconciliation.**
///
/// Lives in its own file so the helper doesn't push `DashboardScreen.swift`
/// over the 600-line `file_length` lint budget.
///
/// **Operator brief (build 17 walkthrough):** the Dashboard's
/// `ComplianceRingCard` rendered "Heute nichts geplant / Keine Einnahmen
/// für heute hinterlegt" on a day where intakes were demonstrably
/// scheduled — the (since-deleted, v0.14.8 AUDIT-HOME M6)
/// `UpcomingMedicationsCard` listed them right above on the
/// same surface. Root cause: the server's `dashboard.summary.compliance`
/// aggregator buckets the user's day in UTC, while
/// `/api/medications/intake?scope=today` buckets in the user's timezone.
/// At 05:23 local (03:23 UTC) the two endpoints disagree on what "today"
/// is, so the compliance snapshot lands with `scheduledToday: 0` while
/// `todayIntakes` carries the (correct) per-tz day.
///
/// **Fix path:** overlay the local snapshot derived from
/// `MedicationsStore.todayIntakes` (the same payload the upcoming-meds
/// card consumes — already user-tz canonical) and pass the widened value
/// to every consumer (`ComplianceRingCard`). We never *narrow* the server
/// count: a day-rollover that
/// happened before iOS reloaded `todayIntakes` keeps the larger value
/// visible until the next refresh.
@MainActor
enum ComplianceReconciler {
    /// Build a corrected `ComplianceSnapshot` for the current Dashboard
    /// render — see file header for the why.
    static func reconcile(
        server: ComplianceSnapshot,
        medicationsStore: MedicationsStore
    ) -> ComplianceSnapshot {
        // W-MED2: feed `derivedTodayIntakes` so the dashboard
        // "Medikamenten-Compliance" tile widens the server's scheduled
        // count by the synthesised placeholders. Pre-fix the tile read
        // `scheduledToday: 0` for the entire pre-RED window even when
        // the operator had a `twice_daily` Lisinopril schedule —
        // operator screenshots reported "Heute nichts geplant" hours
        // after the morning window opened. The reconciler's
        // never-narrow contract still holds: the merge keeps the
        // server-emitted intakes verbatim and only adds the placeholders
        // the server hasn't materialised yet.
        // v0.14.8 AUDIT-compliance F1 — the day-window must be bucketed in the
        // SAME zone the intakes were synthesised in (`profileTimeZone` ==
        // server `userTz`). `reconciled` defaults its `calendar` to `.current`
        // (DEVICE tz); when device-tz ≠ profile-tz near midnight that
        // mismatched the `derivedTodayIntakes` (which are profile-tz canonical)
        // and the Home ring could show a wrong "X von Y / noch offen" count —
        // the exact UTC/profile seam the medications-surface fix already closed.
        // Pass a profile-tz calendar so the Dashboard buckets "today" identically.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = medicationsStore.profileTimeZone
        return ComplianceSnapshot.reconciled(
            server: server,
            todayIntakes: medicationsStore.derivedTodayIntakes,
            activeMedicationIDs: Set(medicationsStore.medications.filter(\.active).map(\.id)),
            // v0.14.8 INV-home-compliance-slot — prefer the empty day-anchored
            // local view over a stale server count once meds are loaded; keep the
            // server snapshot only on a genuine cold start.
            medicationsLoaded: medicationsStore.hasLoadedMedications,
            calendar: calendar
        )
    }
}
