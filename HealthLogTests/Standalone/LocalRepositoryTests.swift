import Foundation
import SwiftData
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

// swiftlint:disable force_unwrapping force_try

// MARK: - Test helpers

/// Per-test in-memory factory for the v0.11 W1 standalone local mirror. Inline
/// (not a base type) so each `@Suite` struct stays under the swiftlint
/// type-body-length ceiling. Mirrors `GLP1TestHelpers`.
enum StandaloneTestHelpers {
    static func makeRepo() throws -> LocalRepository {
        let container = try LocalStore.makeInMemory()
        return LocalRepository(store: LocalStore(modelContainer: container))
    }

    static let medID = "med-standalone-test-id"
    static let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
}

// MARK: - Measurements

@Suite("Standalone measurement CRUD")
struct StandaloneMeasurementTests {
    @Test("Scalar measurement write → read-back round-trips")
    func scalarRoundTrip() async throws {
        let repo = try StandaloneTestHelpers.makeRepo()
        let inserted = try await repo.addMeasurement(
            kind: "weight",
            value: 82.4,
            unit: "kg",
            recordedAt: StandaloneTestHelpers.fixedDate,
            note: "morning"
        )
        let rows = try await repo.measurements(kind: "weight")
        #expect(rows.count == 1)
        #expect(rows[0].externalId == inserted.externalId)
        #expect(rows[0].value == 82.4)
        #expect(rows[0].unit == "kg")
        #expect(rows[0].note == "morning")
        #expect(rows[0].source == "manual")
        #expect(rows[0].recordedAt == StandaloneTestHelpers.fixedDate)
        #expect(rows[0].systolic == nil)
    }

    @Test("Blood-pressure measurement carries systolic/diastolic")
    func bloodPressureRoundTrip() async throws {
        let repo = try StandaloneTestHelpers.makeRepo()
        let inserted = try await repo.addMeasurement(
            kind: "bloodPressure",
            value: 0,
            unit: "mmHg",
            systolic: 128,
            diastolic: 81,
            recordedAt: StandaloneTestHelpers.fixedDate
        )
        let rows = try await repo.measurements(kind: "bloodPressure")
        #expect(rows.count == 1)
        #expect(rows[0].externalId == inserted.externalId)
        #expect(rows[0].systolic == 128)
        #expect(rows[0].diastolic == 81)
    }

    @Test("measurements(kind:) filters by kind")
    func kindFilter() async throws {
        let repo = try StandaloneTestHelpers.makeRepo()
        _ = try await repo.addMeasurement(kind: "weight", value: 80, unit: "kg", recordedAt: .now)
        _ = try await repo.addMeasurement(kind: "glucose", value: 95, unit: "mg/dL", recordedAt: .now)
        let weight = try await repo.measurements(kind: "weight")
        let glucose = try await repo.measurements(kind: "glucose")
        let all = try await repo.measurements()
        #expect(weight.count == 1)
        #expect(glucose.count == 1)
        #expect(all.count == 2)
    }

    @Test("measurements sorted newest-first by recordedAt")
    func newestFirst() async throws {
        let repo = try StandaloneTestHelpers.makeRepo()
        let older = Date(timeIntervalSince1970: 1_700_000_000)
        let newer = Date(timeIntervalSince1970: 1_700_100_000)
        _ = try await repo.addMeasurement(kind: "weight", value: 80, unit: "kg", recordedAt: older)
        _ = try await repo.addMeasurement(kind: "weight", value: 81, unit: "kg", recordedAt: newer)
        let rows = try await repo.measurements(kind: "weight")
        #expect(rows.count == 2)
        #expect(rows[0].recordedAt == newer)
        #expect(rows[1].recordedAt == older)
    }

    @Test("update then delete a measurement")
    func updateThenDelete() async throws {
        let repo = try StandaloneTestHelpers.makeRepo()
        let inserted = try await repo.addMeasurement(
            kind: "weight", value: 80, unit: "kg", recordedAt: StandaloneTestHelpers.fixedDate
        )
        try await repo.updateMeasurement(
            externalId: inserted.externalId,
            value: 79.5,
            unit: "kg",
            recordedAt: StandaloneTestHelpers.fixedDate,
            note: "after diet"
        )
        var rows = try await repo.measurements(kind: "weight")
        #expect(rows[0].value == 79.5)
        #expect(rows[0].note == "after diet")

        try await repo.deleteMeasurement(externalId: inserted.externalId)
        rows = try await repo.measurements(kind: "weight")
        #expect(rows.isEmpty)
    }
}

// MARK: - Moods

@Suite("Standalone mood CRUD")
struct StandaloneMoodTests {
    @Test("Mood write → read-back round-trips with tags")
    func moodRoundTrip() async throws {
        let repo = try StandaloneTestHelpers.makeRepo()
        let inserted = try await repo.addMood(
            score: 4,
            tags: ["calm", "focused"],
            note: "good day",
            recordedAt: StandaloneTestHelpers.fixedDate
        )
        let rows = try await repo.moods()
        #expect(rows.count == 1)
        #expect(rows[0].externalId == inserted.externalId)
        #expect(rows[0].score == 4)
        #expect(rows[0].tags == ["calm", "focused"])
        #expect(rows[0].note == "good day")
    }

    @Test("Mood score is clamped into 1...5")
    func scoreClamped() async throws {
        let repo = try StandaloneTestHelpers.makeRepo()
        _ = try await repo.addMood(score: 9, recordedAt: .now)
        _ = try await repo.addMood(score: -3, recordedAt: .now)
        let rows = try await repo.moods()
        #expect(rows.allSatisfy { (1 ... 5).contains($0.score) })
    }

    @Test("moods(days:) filters by recency window")
    func daysFilter() async throws {
        let repo = try StandaloneTestHelpers.makeRepo()
        let recent = Date()
        let old = try #require(Calendar.current.date(byAdding: .day, value: -30, to: recent))
        _ = try await repo.addMood(score: 3, recordedAt: recent)
        _ = try await repo.addMood(score: 2, recordedAt: old)
        let last7 = try await repo.moods(days: 7)
        let all = try await repo.moods()
        #expect(last7.count == 1)
        #expect(all.count == 2)
    }
}

// MARK: - Intakes

@Suite("Standalone intake CRUD")
struct StandaloneIntakeTests {
    @Test("Intake write → read-back round-trips")
    func intakeRoundTrip() async throws {
        let repo = try StandaloneTestHelpers.makeRepo()
        let inserted = try await repo.addIntake(
            medicationId: StandaloneTestHelpers.medID,
            takenAt: StandaloneTestHelpers.fixedDate,
            status: "taken",
            note: "with food"
        )
        let rows = try await repo.intakes(medicationId: StandaloneTestHelpers.medID)
        #expect(rows.count == 1)
        #expect(rows[0].externalId == inserted.externalId)
        #expect(rows[0].medicationId == StandaloneTestHelpers.medID)
        #expect(rows[0].status == "taken")
        #expect(rows[0].note == "with food")
    }

    @Test("intakes(medicationId:) filters by medication")
    func medicationFilter() async throws {
        let repo = try StandaloneTestHelpers.makeRepo()
        _ = try await repo.addIntake(medicationId: "med-a", takenAt: .now, status: "taken")
        _ = try await repo.addIntake(medicationId: "med-b", takenAt: .now, status: "skipped")
        let a = try await repo.intakes(medicationId: "med-a")
        let all = try await repo.intakes()
        #expect(a.count == 1)
        #expect(a[0].status == "taken")
        #expect(all.count == 2)
    }

    /// v0.13 WP — offline injection logs its site like the paired path.
    @Test("Taken injection persists its site → reads back round-trip")
    func injectionSiteRoundTrip() async throws {
        let repo = try StandaloneTestHelpers.makeRepo()
        let inserted = try await repo.addIntake(
            medicationId: StandaloneTestHelpers.medID,
            takenAt: StandaloneTestHelpers.fixedDate,
            status: "taken",
            injectionSite: "ABDOMEN_UPPER_LEFT"
        )
        let rows = try await repo.intakes(medicationId: StandaloneTestHelpers.medID)
        #expect(rows.count == 1)
        #expect(rows[0].externalId == inserted.externalId)
        #expect(rows[0].injectionSite == "ABDOMEN_UPPER_LEFT")
        #expect(inserted.injectionSite == "ABDOMEN_UPPER_LEFT")
    }

    /// A site only rides a `taken` dose — mirrors the paired `record(intake:)`
    /// gate (`status == .taken ? site : nil`).
    @Test("Non-taken disposition drops the injection site")
    func injectionSiteOnlyOnTaken() async throws {
        let repo = try StandaloneTestHelpers.makeRepo()
        _ = try await repo.addIntake(
            medicationId: StandaloneTestHelpers.medID,
            takenAt: .now,
            status: "skipped",
            injectionSite: "THIGH_LEFT"
        )
        let rows = try await repo.intakes(medicationId: StandaloneTestHelpers.medID)
        #expect(rows.count == 1)
        #expect(rows[0].injectionSite == nil)
    }

    @Test("update then delete an intake")
    func updateThenDelete() async throws {
        let repo = try StandaloneTestHelpers.makeRepo()
        let inserted = try await repo.addIntake(
            medicationId: StandaloneTestHelpers.medID, takenAt: .now, status: "taken"
        )
        try await repo.updateIntake(
            externalId: inserted.externalId, takenAt: .now, status: "skipped", note: "felt sick"
        )
        var rows = try await repo.intakes(medicationId: StandaloneTestHelpers.medID)
        #expect(rows[0].status == "skipped")
        #expect(rows[0].note == "felt sick")

        try await repo.deleteIntake(externalId: inserted.externalId)
        rows = try await repo.intakes(medicationId: StandaloneTestHelpers.medID)
        #expect(rows.isEmpty)
    }
}

// MARK: - Cross-cutting (uniqueness, backfill, recovery, sanitation)

@Suite("Standalone mirror invariants")
struct StandaloneInvariantTests {
    @Test("externalId #Unique upsert collapses duplicate writes onto one row")
    func externalIdUnique() async throws {
        let container = try LocalStore.makeInMemory()
        let store = LocalStore(modelContainer: container)
        let id = UUID().uuidString
        // Two inserts with the SAME externalId must collapse to one row
        // (#Unique upsert), not throw or duplicate.
        try await store.insertMeasurement(
            LocalMeasurementSnapshot(
                externalId: id, kind: "weight", value: 80, unit: "kg",
                recordedAt: StandaloneTestHelpers.fixedDate, createdAt: .now
            )
        )
        try await store.insertMeasurement(
            LocalMeasurementSnapshot(
                externalId: id, kind: "weight", value: 81, unit: "kg",
                recordedAt: StandaloneTestHelpers.fixedDate, createdAt: .now
            )
        )
        let rows = try await store.snapshotMeasurements(kind: "weight", limit: nil)
        #expect(rows.count == 1)
        #expect(rows[0].externalId == id)
        #expect(rows[0].value == 81) // upsert kept the latest value
    }

    @Test("allForBackfill returns every row across all three tables")
    func backfillBundle() async throws {
        let repo = try StandaloneTestHelpers.makeRepo()
        _ = try await repo.addMeasurement(kind: "weight", value: 80, unit: "kg", recordedAt: .now)
        _ = try await repo.addMood(score: 3, recordedAt: .now)
        _ = try await repo.addIntake(medicationId: "m", takenAt: .now, status: "taken")
        let bundle = try await repo.allForBackfill()
        #expect(bundle.measurements.count == 1)
        #expect(bundle.moods.count == 1)
        #expect(bundle.intakes.count == 1)
        #expect(!bundle.isEmpty)
    }

    @Test("deleteAll wipes every table")
    func deleteAllWipes() async throws {
        let repo = try StandaloneTestHelpers.makeRepo()
        _ = try await repo.addMeasurement(kind: "weight", value: 80, unit: "kg", recordedAt: .now)
        _ = try await repo.addMood(score: 3, recordedAt: .now)
        _ = try await repo.addIntake(medicationId: "m", takenAt: .now, status: "taken")
        try await repo.deleteAll()
        let bundle = try await repo.allForBackfill()
        #expect(bundle.isEmpty)
    }

    @Test("Empty / whitespace note is normalised to nil")
    func noteSanitation() async throws {
        let repo = try StandaloneTestHelpers.makeRepo()
        _ = try await repo.addMeasurement(
            kind: "weight", value: 80, unit: "kg", recordedAt: .now, note: "   "
        )
        let rows = try await repo.measurements(kind: "weight")
        #expect(rows[0].note == nil)
    }

    @Test("makeWithRecovery yields a usable repository (recovery path smoke)")
    func recoverySmoke() async throws {
        // Production factory must always return a working repo even if the
        // persistent store has to fall back to in-memory. Smoke-test the
        // write→read path through the recovered instance.
        let repo = LocalRepository.makeWithRecovery()
        let inserted = try await repo.addMood(score: 5, recordedAt: StandaloneTestHelpers.fixedDate)
        let rows = try await repo.moods()
        #expect(rows.contains { $0.externalId == inserted.externalId })
        // Clean up so the on-disk store doesn't leak between test runs.
        try await repo.deleteAll()
    }

    @Test("makeWithRecoveryTask defers the open yet is fully usable on first access (audit P-1)")
    func deferredOpenSmoke() async throws {
        // audit P-1 — the composition root builds the mirror via the deferred
        // factory so the SwiftData container open never runs on the cold-launch
        // tick. The container must open lazily on the FIRST actual read/write
        // and behave identically to the synchronous repo (no nil-store crash,
        // no lost write). Exercise a write → read round-trip through a
        // deferred-built instance to prove first-access resolution works.
        let repo = LocalRepository.makeWithRecoveryTask()
        let inserted = try await repo.addMood(score: 4, recordedAt: StandaloneTestHelpers.fixedDate)
        let rows = try await repo.moods()
        #expect(rows.contains { $0.externalId == inserted.externalId })
        // A second access must reuse the memoised store (idempotent resolve).
        let again = try await repo.moods()
        #expect(again.count == rows.count)
        // Clean up so the on-disk store doesn't leak between test runs.
        try await repo.deleteAll()
    }

    @Test("Snapshot fidelity — every field survives the actor boundary")
    func snapshotFidelity() async throws {
        let repo = try StandaloneTestHelpers.makeRepo()
        let inserted = try await repo.addMeasurement(
            kind: "bloodPressure",
            value: 0,
            unit: "mmHg",
            systolic: 130,
            diastolic: 85,
            recordedAt: StandaloneTestHelpers.fixedDate,
            note: "evening",
            source: "manual"
        )
        let rows = try await repo.measurements(kind: "bloodPressure")
        let row = try #require(rows.first)
        #expect(row.externalId == inserted.externalId)
        #expect(row.kind == "bloodPressure")
        #expect(row.unit == "mmHg")
        #expect(row.systolic == 130)
        #expect(row.diastolic == 85)
        #expect(row.note == "evening")
        #expect(row.source == "manual")
        #expect(row.recordedAt == StandaloneTestHelpers.fixedDate)
    }
}

// swiftlint:enable force_unwrapping force_try
