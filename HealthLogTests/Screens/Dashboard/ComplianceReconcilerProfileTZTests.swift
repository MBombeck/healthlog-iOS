import Foundation
@testable import HealthLog
import Testing

/// **v0.14.x AUDIT-compliance F1 / INV-home-compliance-slot — HOME-5
/// (DOSE-SAFETY).** The Home compliance ring count must bucket "today" in the
/// user's `profileTimeZone` (== server `userTz`), NEVER the DEVICE timezone.
/// Pre-fix `ComplianceReconciler.reconcile` let `ComplianceSnapshot.reconciled`
/// default its `calendar` to `.current` (device tz); when the traveller's
/// device tz differs from their profile tz near midnight, the day-window filter
/// and the (profile-tz-canonical) `derivedTodayIntakes` disagreed and the ring
/// could over/under-count doses — the exact UTC/profile seam the medications
/// surface already closed.
///
/// These tests exercise the STORE-FACING entry point `ComplianceReconciler
/// .reconcile(server:medicationsStore:)` (not the already-covered pure
/// `ComplianceSnapshot.reconciled`), so they prove the wiring actually threads
/// `medicationsStore.profileTimeZone` into the reconciler's calendar. The pure
/// function's tz behaviour is verified separately in
/// `ComplianceSnapshotReconciledTests`.
@Suite("ComplianceReconciler — profile-tz day bucketing (HOME-5 DOSE-SAFETY)")
@MainActor
struct ComplianceReconcilerProfileTZTests {
    private func makeStore() throws -> MedicationsStore {
        let api = StubAPIClient()
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MedicationsRepository(api: api, outbox: outbox)
        return MedicationsStore(repo: repo)
    }

    private func medication(id: String) -> Medication {
        Medication(
            id: id,
            name: "Lisinopril",
            dose: "5 mg",
            // Empty schedule so `derivedTodayIntakes` synthesises NO extra
            // placeholders — the count is exactly the seeded server rows that
            // fall inside the profile-tz "today" window. Keeps the assertion
            // about the day-window boundary, not about slot synthesis.
            schedule: MedicationSchedule(times: [], weekdays: nil, intervalWeeks: 1)
        )
    }

    private func intake(id: String, medID: String, scheduledAt: Date) -> MedicationIntake {
        MedicationIntake(
            id: id,
            medicationId: medID,
            scheduledAt: scheduledAt,
            takenAt: nil,
            status: .pending
        )
    }

    /// Near-midnight proof: an intake stamped just after the profile-tz
    /// start-of-day is INSIDE the profile-tz "today" window and must be counted,
    /// while the SAME instant can fall on the PREVIOUS day in a device tz that
    /// is hours behind. The reconciler must use the profile zone → count == 1.
    @Test("near-midnight intake at profile-tz start-of-day counts in profile tz, not device tz")
    func nearMidnightCountsInProfileTZ() throws {
        let store = try makeStore()
        // Profile zone deliberately FAR from the test host's device zone so the
        // wiring (not an accidental `.current` match) is what makes this pass.
        let profileTZ = try #require(TimeZone(identifier: "Pacific/Kiritimati")) // UTC+14
        store.profileTimeZoneProvider = { profileTZ }

        let med = medication(id: "med-A")
        store._testForceSet(medications: [med])

        // Place the intake 30 minutes AFTER the profile-tz start-of-day for
        // "now" — unambiguously inside today's profile-tz window, but in a
        // device tz several hours behind (e.g. UTC-11) the same wall-clock
        // instant would still belong to the prior calendar day.
        var profileCal = Calendar(identifier: .gregorian)
        profileCal.timeZone = profileTZ
        let startOfTodayProfile = profileCal.startOfDay(for: .now)
        let scheduledAt = try #require(
            profileCal.date(byAdding: .minute, value: 30, to: startOfTodayProfile)
        )
        store._testForceSet(todayIntakes: [intake(id: "i1", medID: med.id, scheduledAt: scheduledAt)])

        // Server snapshot is deliberately empty (cold/stale) so the count can
        // only come from the profile-tz local derivation.
        let reconciled = ComplianceReconciler.reconcile(
            server: ComplianceSnapshot(scheduledToday: 0, takenToday: 0),
            medicationsStore: store
        )

        #expect(reconciled.scheduledToday == 1, "profile-tz today-window must include the post-midnight intake")
        #expect(reconciled.hasSchedule == true)
    }

    /// Symmetric proof at the day boundary: two intakes around the profile-tz
    /// midnight — one 30 min AFTER start-of-day (belongs to TODAY in the profile
    /// zone), one 30 min BEFORE (belongs to YESTERDAY). The reconciler must
    /// count exactly the post-midnight one (1), proving the day window is cut on
    /// the profile-tz boundary and not a device-tz boundary that could include
    /// (or exclude) the wrong one. This stays on the `localScheduled > 0` branch
    /// so it asserts the boundary math directly, independent of the
    /// cold-start/loaded distinction.
    @Test("profile-tz day boundary excludes the before-midnight intake")
    func dayBoundaryCutInProfileTZ() throws {
        let store = try makeStore()
        let profileTZ = try #require(TimeZone(identifier: "Pacific/Kiritimati")) // UTC+14
        store.profileTimeZoneProvider = { profileTZ }

        let med = medication(id: "med-A")
        store._testForceSet(medications: [med])

        var profileCal = Calendar(identifier: .gregorian)
        profileCal.timeZone = profileTZ
        let startOfTodayProfile = profileCal.startOfDay(for: .now)
        let afterMidnight = try #require(
            profileCal.date(byAdding: .minute, value: 30, to: startOfTodayProfile)
        )
        let beforeMidnight = try #require(
            profileCal.date(byAdding: .minute, value: -30, to: startOfTodayProfile)
        )
        store._testForceSet(todayIntakes: [
            intake(id: "today", medID: med.id, scheduledAt: afterMidnight),
            intake(id: "yesterday", medID: med.id, scheduledAt: beforeMidnight)
        ])

        let reconciled = ComplianceReconciler.reconcile(
            server: ComplianceSnapshot(scheduledToday: 0, takenToday: 0),
            medicationsStore: store
        )

        #expect(
            reconciled.scheduledToday == 1,
            "only the post-midnight (today, profile tz) intake may count — the before-midnight one is yesterday"
        )
    }

    /// Control: with `profileTimeZoneProvider` left at its `.current` default,
    /// an intake anchored on the DEVICE start-of-day still counts — confirming
    /// the wiring doesn't break the common (device == profile) case while it
    /// fixes the traveller seam.
    @Test("default provider (.current) still counts a device-day intake")
    func defaultProviderCountsDeviceDay() throws {
        let store = try makeStore()
        let med = medication(id: "med-A")
        store._testForceSet(medications: [med])

        var deviceCal = Calendar(identifier: .gregorian)
        deviceCal.timeZone = .current
        let scheduledAt = try #require(
            deviceCal.date(byAdding: .minute, value: 30, to: deviceCal.startOfDay(for: .now))
        )
        store._testForceSet(todayIntakes: [intake(id: "i1", medID: med.id, scheduledAt: scheduledAt)])

        let reconciled = ComplianceReconciler.reconcile(
            server: ComplianceSnapshot(scheduledToday: 0, takenToday: 0),
            medicationsStore: store
        )

        #expect(reconciled.scheduledToday == 1)
    }
}
