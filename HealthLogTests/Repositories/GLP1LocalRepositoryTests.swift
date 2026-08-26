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

/// Per-test in-memory factory. Inline rather than on a base type so each
/// `@Suite` struct stays under the swiftlint type-body-length ceiling.
enum GLP1TestHelpers {
    static func makeRepo() throws -> GLP1LocalRepository {
        let container = try GLP1LocalStore.makeInMemory()
        return GLP1LocalRepository(store: GLP1LocalStore(modelContainer: container))
    }

    static let medID = "med-test-id"
}

// MARK: - Titration

@Suite("GLP-1 titration CRUD")
struct GLP1TitrationTests {
    @Test("Titration step round-trip")
    func titrationRoundTrip() async throws {
        let repo = try GLP1TestHelpers.makeRepo()
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        let inserted = try await repo.addTitrationStep(
            medicationID: GLP1TestHelpers.medID,
            effectiveFrom: when,
            doseMg: 5.0,
            note: "Step up"
        )
        let snapshots = try await repo.titrationSteps(medicationID: GLP1TestHelpers.medID)
        #expect(snapshots.count == 1)
        #expect(snapshots[0].id == inserted.id)
        #expect(snapshots[0].doseMg == 5.0)
        #expect(snapshots[0].note == "Step up")
        #expect(snapshots[0].effectiveFrom == when)
    }

    @Test("Titration step update mutates and persists")
    func titrationUpdate() async throws {
        let repo = try GLP1TestHelpers.makeRepo()
        let inserted = try await repo.addTitrationStep(
            medicationID: GLP1TestHelpers.medID,
            effectiveFrom: .now,
            doseMg: 5.0,
            note: nil
        )
        let newDate = Date(timeIntervalSince1970: 1_800_000_000)
        try await repo.updateTitrationStep(
            id: inserted.id,
            effectiveFrom: newDate,
            doseMg: 7.5,
            note: "moved up"
        )
        let snapshots = try await repo.titrationSteps(medicationID: GLP1TestHelpers.medID)
        #expect(snapshots.count == 1)
        #expect(snapshots[0].doseMg == 7.5)
        #expect(snapshots[0].note == "moved up")
        #expect(snapshots[0].effectiveFrom == newDate)
    }

    @Test("Titration step delete removes row")
    func titrationDelete() async throws {
        let repo = try GLP1TestHelpers.makeRepo()
        let a = try await repo.addTitrationStep(
            medicationID: GLP1TestHelpers.medID,
            effectiveFrom: Date(timeIntervalSince1970: 1_700_000_000),
            doseMg: 2.5,
            note: nil
        )
        _ = try await repo.addTitrationStep(
            medicationID: GLP1TestHelpers.medID,
            effectiveFrom: Date(timeIntervalSince1970: 1_800_000_000),
            doseMg: 5.0,
            note: nil
        )
        try await repo.deleteTitrationStep(id: a.id)
        let snapshots = try await repo.titrationSteps(medicationID: GLP1TestHelpers.medID)
        #expect(snapshots.count == 1)
        #expect(snapshots[0].doseMg == 5.0)
    }

    @Test("Titration steps sort ascending by effectiveFrom")
    func titrationSortsAscending() async throws {
        let repo = try GLP1TestHelpers.makeRepo()
        _ = try await repo.addTitrationStep(
            medicationID: GLP1TestHelpers.medID,
            effectiveFrom: Date(timeIntervalSince1970: 1_800_000_000),
            doseMg: 7.5,
            note: nil
        )
        _ = try await repo.addTitrationStep(
            medicationID: GLP1TestHelpers.medID,
            effectiveFrom: Date(timeIntervalSince1970: 1_700_000_000),
            doseMg: 5.0,
            note: nil
        )
        let snapshots = try await repo.titrationSteps(medicationID: GLP1TestHelpers.medID)
        #expect(snapshots.map(\.doseMg) == [5.0, 7.5])
    }

    @Test("Titration dose clamped to sanity ceiling")
    func titrationClampsDose() async throws {
        let repo = try GLP1TestHelpers.makeRepo()
        let inserted = try await repo.addTitrationStep(
            medicationID: GLP1TestHelpers.medID,
            effectiveFrom: .now,
            doseMg: 5000, // way above the 100 mg ceiling
            note: nil
        )
        #expect(inserted.doseMg == GLP1LocalRepository.maxDoseMg)
        let negative = try await repo.addTitrationStep(
            medicationID: GLP1TestHelpers.medID,
            effectiveFrom: .now,
            doseMg: -1.0,
            note: nil
        )
        #expect(negative.doseMg == 0)
    }

    @Test("Titration note trimmed and capped")
    func titrationNoteSanitized() async throws {
        let repo = try GLP1TestHelpers.makeRepo()
        let blank = try await repo.addTitrationStep(
            medicationID: GLP1TestHelpers.medID,
            effectiveFrom: .now,
            doseMg: 5,
            note: "   "
        )
        #expect(blank.note == nil)
        let long = String(repeating: "a", count: 1000)
        let capped = try await repo.addTitrationStep(
            medicationID: GLP1TestHelpers.medID,
            effectiveFrom: .now,
            doseMg: 5,
            note: long
        )
        #expect(capped.note?.count == GLP1LocalRepository.maxNoteLength)
    }
}

// MARK: - Side-effects

@Suite("GLP-1 side-effect CRUD")
struct GLP1SideEffectTests {
    @Test("Side-effect round-trip with severity clamp")
    func sideEffectRoundTrip() async throws {
        let repo = try GLP1TestHelpers.makeRepo()
        // Use a "today" timestamp so the default sinceDays window picks
        // it up regardless of when the test runs.
        let when = Date.now
        let inserted = try await repo.addSideEffect(
            medicationID: GLP1TestHelpers.medID,
            loggedAt: when,
            kind: .nausea,
            severity: 5, // clamp to 3
            note: "after dinner"
        )
        #expect(inserted.severity == 3)
        let snapshots = try await repo.sideEffects(
            medicationID: GLP1TestHelpers.medID,
            sinceDays: 365
        )
        #expect(snapshots.count == 1)
        #expect(snapshots[0].kind == .nausea)
        #expect(snapshots[0].severity == 3)
        #expect(snapshots[0].note == "after dinner")
    }

    @Test("Side-effect sinceDays window filters older rows")
    func sideEffectWindow() async throws {
        let repo = try GLP1TestHelpers.makeRepo()
        let old = try #require(Calendar.current.date(byAdding: .day, value: -100, to: .now))
        let recent = try #require(Calendar.current.date(byAdding: .day, value: -5, to: .now))
        _ = try await repo.addSideEffect(
            medicationID: GLP1TestHelpers.medID,
            loggedAt: old,
            kind: .nausea,
            severity: 2,
            note: nil
        )
        _ = try await repo.addSideEffect(
            medicationID: GLP1TestHelpers.medID,
            loggedAt: recent,
            kind: .fatigue,
            severity: 1,
            note: nil
        )
        let snapshots = try await repo.sideEffects(
            medicationID: GLP1TestHelpers.medID,
            sinceDays: 30
        )
        #expect(snapshots.count == 1)
        #expect(snapshots[0].kind == .fatigue)
    }

    @Test("Side-effect sorts newest first")
    func sideEffectSortDescending() async throws {
        let repo = try GLP1TestHelpers.makeRepo()
        _ = try await repo.addSideEffect(
            medicationID: GLP1TestHelpers.medID,
            loggedAt: Date(timeIntervalSince1970: 1_700_000_000),
            kind: .nausea,
            severity: 1,
            note: nil
        )
        _ = try await repo.addSideEffect(
            medicationID: GLP1TestHelpers.medID,
            loggedAt: Date(timeIntervalSince1970: 1_800_000_000),
            kind: .fatigue,
            severity: 2,
            note: nil
        )
        let snapshots = try await repo.sideEffects(
            medicationID: GLP1TestHelpers.medID,
            sinceDays: 100_000
        )
        #expect(snapshots.map(\.kind) == [.fatigue, .nausea])
    }

    @Test("Side-effect kind decode handles unknown raw")
    func sideEffectUnknownKindDegrades() {
        // Simulate forward-compat: a future build writes a kind raw the
        // current build doesn't know about.
        let snapshot = SideEffectEntrySnapshot(
            id: "x",
            medicationID: GLP1TestHelpers.medID,
            loggedAt: .now,
            kindRaw: "future_kind_xyz",
            severity: 1,
            note: nil,
            createdAt: .now
        )
        #expect(snapshot.kind == nil)
    }

    @Test("Side-effect delete removes row")
    func sideEffectDelete() async throws {
        let repo = try GLP1TestHelpers.makeRepo()
        let entry = try await repo.addSideEffect(
            medicationID: GLP1TestHelpers.medID,
            loggedAt: .now,
            kind: .nausea,
            severity: 1,
            note: nil
        )
        try await repo.deleteSideEffect(id: entry.id)
        let snapshots = try await repo.sideEffects(
            medicationID: GLP1TestHelpers.medID,
            sinceDays: 365
        )
        #expect(snapshots.isEmpty)
    }
}

// MARK: - Pen inventory

@Suite("GLP-1 pen inventory CRUD")
struct GLP1PenInventoryTests {
    @Test("Pen inventory round-trip")
    func penRoundTrip() async throws {
        let repo = try GLP1TestHelpers.makeRepo()
        let dispensed = Date(timeIntervalSince1970: 1_700_000_000)
        let inserted = try await repo.addPen(
            medicationID: GLP1TestHelpers.medID,
            manufacturer: "Lilly",
            doseStrength: "5 mg / dose",
            dispensedAt: dispensed,
            firstUsedAt: nil,
            notes: "Pharmacy run"
        )
        let snapshots = try await repo.pens(medicationID: GLP1TestHelpers.medID)
        #expect(snapshots.count == 1)
        #expect(snapshots[0].id == inserted.id)
        #expect(snapshots[0].manufacturer == "Lilly")
        #expect(snapshots[0].doseStrength == "5 mg / dose")
        #expect(snapshots[0].isActive == false)
        #expect(snapshots[0].isFinished == false)
    }

    @Test("Pen markFinished updates state")
    func penMarkFinished() async throws {
        let repo = try GLP1TestHelpers.makeRepo()
        let inserted = try await repo.addPen(
            medicationID: GLP1TestHelpers.medID,
            manufacturer: "Novo",
            doseStrength: "1 mg",
            dispensedAt: .now,
            firstUsedAt: .now,
            notes: nil
        )
        // Active before finish
        var snapshots = try await repo.pens(medicationID: GLP1TestHelpers.medID)
        #expect(snapshots[0].isActive == true)
        let finishedAt = Date(timeIntervalSince1970: 1_800_000_000)
        try await repo.markPenFinished(id: inserted.id, finishedAt: finishedAt)
        snapshots = try await repo.pens(medicationID: GLP1TestHelpers.medID)
        #expect(snapshots[0].isFinished == true)
        #expect(snapshots[0].finishedAt == finishedAt)
    }

    @Test("Pen sort newest dispensed-first")
    func penSortNewestFirst() async throws {
        let repo = try GLP1TestHelpers.makeRepo()
        _ = try await repo.addPen(
            medicationID: GLP1TestHelpers.medID,
            manufacturer: "Old",
            doseStrength: "1 mg",
            dispensedAt: Date(timeIntervalSince1970: 1_700_000_000),
            firstUsedAt: nil,
            notes: nil
        )
        _ = try await repo.addPen(
            medicationID: GLP1TestHelpers.medID,
            manufacturer: "Recent",
            doseStrength: "1 mg",
            dispensedAt: Date(timeIntervalSince1970: 1_800_000_000),
            firstUsedAt: nil,
            notes: nil
        )
        let snapshots = try await repo.pens(medicationID: GLP1TestHelpers.medID)
        #expect(snapshots.map(\.manufacturer) == ["Recent", "Old"])
    }

    @Test("Pen delete removes row")
    func penDelete() async throws {
        let repo = try GLP1TestHelpers.makeRepo()
        let inserted = try await repo.addPen(
            medicationID: GLP1TestHelpers.medID,
            manufacturer: "X",
            doseStrength: "Y",
            dispensedAt: .now,
            firstUsedAt: nil,
            notes: nil
        )
        try await repo.deletePen(id: inserted.id)
        let snapshots = try await repo.pens(medicationID: GLP1TestHelpers.medID)
        #expect(snapshots.isEmpty)
    }
}

// MARK: - Injection sites

@Suite("GLP-1 injection-site CRUD")
struct GLP1InjectionSiteTests {
    @Test("Injection site round-trip")
    func siteRoundTrip() async throws {
        let repo = try GLP1TestHelpers.makeRepo()
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        let inserted = try await repo.addSite(
            medicationID: GLP1TestHelpers.medID,
            injectedAt: when,
            site: .abdomenLeftUpper,
            note: nil
        )
        let snapshots = try await repo.sites(medicationID: GLP1TestHelpers.medID)
        #expect(snapshots.count == 1)
        #expect(snapshots[0].id == inserted.id)
        #expect(snapshots[0].site == .abdomenLeftUpper)
        #expect(snapshots[0].injectedAt == when)
    }

    @Test("Injection sites sort newest first with limit")
    func siteSortAndLimit() async throws {
        let repo = try GLP1TestHelpers.makeRepo()
        for offset in 0 ..< 5 {
            _ = try await repo.addSite(
                medicationID: GLP1TestHelpers.medID,
                injectedAt: Date(timeIntervalSince1970: Double(1_700_000_000 + offset * 100)),
                site: .abdomenLeftUpper,
                note: nil
            )
        }
        let snapshots = try await repo.sites(medicationID: GLP1TestHelpers.medID, limit: 3)
        #expect(snapshots.count == 3)
        // Newest first
        #expect(snapshots[0].injectedAt > snapshots[1].injectedAt)
    }

    @Test("Injection site delete removes row")
    func siteDelete() async throws {
        let repo = try GLP1TestHelpers.makeRepo()
        let inserted = try await repo.addSite(
            medicationID: GLP1TestHelpers.medID,
            injectedAt: .now,
            site: .thighLeft,
            note: nil
        )
        try await repo.deleteSite(id: inserted.id)
        let snapshots = try await repo.sites(medicationID: GLP1TestHelpers.medID)
        #expect(snapshots.isEmpty)
    }

    @Test("InjectionSite.parse handles canonical + unknown values")
    func injectionSiteParse() {
        #expect(InjectionSite.parse("abdomen_left_upper") == .abdomenLeftUpper)
        #expect(InjectionSite.parse("  THIGH_LEFT  ") == .thighLeft)
        #expect(InjectionSite.parse(nil) == nil)
        #expect(InjectionSite.parse("") == nil)
        #expect(InjectionSite.parse("not_a_site") == nil)
    }
}

// MARK: - Cascade + scoping

@Suite("GLP-1 cascade + cross-medication scoping")
struct GLP1CascadeTests {
    @Test("deleteAllForMedication wipes across all four tables")
    func cascadeDelete() async throws {
        let repo = try GLP1TestHelpers.makeRepo()
        _ = try await repo.addTitrationStep(
            medicationID: GLP1TestHelpers.medID,
            effectiveFrom: .now,
            doseMg: 5,
            note: nil
        )
        _ = try await repo.addSideEffect(
            medicationID: GLP1TestHelpers.medID,
            loggedAt: .now,
            kind: .nausea,
            severity: 1,
            note: nil
        )
        _ = try await repo.addPen(
            medicationID: GLP1TestHelpers.medID,
            manufacturer: "X",
            doseStrength: "1 mg",
            dispensedAt: .now,
            firstUsedAt: nil,
            notes: nil
        )
        _ = try await repo.addSite(
            medicationID: GLP1TestHelpers.medID,
            injectedAt: .now,
            site: .armLeft,
            note: nil
        )
        // Add a row on a different medication to verify isolation.
        _ = try await repo.addTitrationStep(
            medicationID: "other-med",
            effectiveFrom: .now,
            doseMg: 5,
            note: nil
        )

        try await repo.deleteAllForMedication(GLP1TestHelpers.medID)

        let titration = try await repo.titrationSteps(medicationID: GLP1TestHelpers.medID)
        let effects = try await repo.sideEffects(
            medicationID: GLP1TestHelpers.medID,
            sinceDays: 365
        )
        let pens = try await repo.pens(medicationID: GLP1TestHelpers.medID)
        let sites = try await repo.sites(medicationID: GLP1TestHelpers.medID)
        #expect(titration.isEmpty)
        #expect(effects.isEmpty)
        #expect(pens.isEmpty)
        #expect(sites.isEmpty)
        // Other medication untouched.
        let other = try await repo.titrationSteps(medicationID: "other-med")
        #expect(other.count == 1)
    }

    @Test("deleteAll wipes everything")
    func wipeAll() async throws {
        let repo = try GLP1TestHelpers.makeRepo()
        _ = try await repo.addTitrationStep(
            medicationID: "a",
            effectiveFrom: .now,
            doseMg: 5,
            note: nil
        )
        _ = try await repo.addSideEffect(
            medicationID: "b",
            loggedAt: .now,
            kind: .nausea,
            severity: 1,
            note: nil
        )
        try await repo.deleteAll()
        let titration = try await repo.titrationSteps(medicationID: "a")
        let effects = try await repo.sideEffects(medicationID: "b", sinceDays: 365)
        #expect(titration.isEmpty)
        #expect(effects.isEmpty)
    }

    @Test("entries are scoped by medicationID")
    func crossMedicationScoping() async throws {
        let repo = try GLP1TestHelpers.makeRepo()
        _ = try await repo.addTitrationStep(
            medicationID: "med-A",
            effectiveFrom: .now,
            doseMg: 1,
            note: nil
        )
        _ = try await repo.addTitrationStep(
            medicationID: "med-B",
            effectiveFrom: .now,
            doseMg: 2,
            note: nil
        )
        let aRows = try await repo.titrationSteps(medicationID: "med-A")
        let bRows = try await repo.titrationSteps(medicationID: "med-B")
        #expect(aRows.count == 1)
        #expect(bRows.count == 1)
        #expect(aRows[0].doseMg == 1)
        #expect(bRows[0].doseMg == 2)
    }
}

// MARK: - InjectionSiteRotation pure-function helper

@Suite("Injection-site rotation suggestion")
struct InjectionSiteRotationTests {
    @Test("Empty history yields nil suggestion")
    func emptyYieldsNil() {
        #expect(InjectionSiteRotation.suggestNext(recent: []) == nil)
    }

    @Test("Single most-recent site is not suggested again")
    func avoidsMostRecent() {
        // After abdomen-left-upper, expect the least-used site that isn't
        // that one. With only one recent injection every other site has
        // count 0; the tie-break prefers the site furthest from the most
        // recent — that's any non-abdomen site.
        let suggestion = InjectionSiteRotation.suggestNext(recent: [.abdomenLeftUpper])
        #expect(suggestion != .abdomenLeftUpper)
    }

    @Test("Repeated same-site history forces rotation away")
    func forcesRotation() {
        let history: [InjectionSite] = Array(repeating: .abdomenLeftUpper, count: 4)
        let suggestion = InjectionSiteRotation.suggestNext(recent: history)
        #expect(suggestion != .abdomenLeftUpper)
    }

    @Test("Even rotation produces stable suggestion")
    func evenRotation() {
        // Window of 8: every site used once. All ties → tie-break by
        // distance-from-most-recent; the most-recent is whatever the
        // first entry is in the `recent` array (newest-first ordering).
        let history: [InjectionSite] = InjectionSite.allCases
        let suggestion = InjectionSiteRotation.suggestNext(recent: history)
        #expect(suggestion != nil)
        // Not the most-recent.
        #expect(suggestion != history[0])
    }

    @Test("Rotation respects window size")
    func respectsWindow() {
        // 10 same-site injections in history, window = 4. Should still
        // suggest away from the most-recent.
        let history: [InjectionSite] = Array(repeating: .thighLeft, count: 10)
        let suggestion = InjectionSiteRotation.suggestNext(recent: history, window: 4)
        #expect(suggestion != .thighLeft)
    }
}
