import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

// swiftlint:disable force_unwrapping

/// State-level coverage for `SideEffectsLogbookStore`.
@Suite("Side-effects logbook store")
@MainActor
struct SideEffectsLogbookStoreTests {
    private func makeRepo() throws -> GLP1LocalRepository {
        let container = try GLP1LocalStore.makeInMemory()
        return GLP1LocalRepository(store: GLP1LocalStore(modelContainer: container))
    }

    private let medID = "med-X"

    @Test("Empty load yields empty state")
    func emptyLoad() async throws {
        let repo = try makeRepo()
        let store = SideEffectsLogbookStore(medicationID: medID, repo: repo)
        await store.load()
        #expect(store.entries.isEmpty)
        #expect(store.summaryByKind.isEmpty)
        #expect(store.entriesByDay.isEmpty)
    }

    @Test("Log appends, sorted newest-first")
    func logAppends() async throws {
        let repo = try makeRepo()
        let store = SideEffectsLogbookStore(medicationID: medID, repo: repo)
        let now = Date.now
        let earlier = try #require(Calendar.current.date(byAdding: .day, value: -1, to: now))
        await store.log(loggedAt: earlier, kind: .nausea, severity: 1, note: nil)
        await store.log(loggedAt: now, kind: .fatigue, severity: 2, note: nil)
        #expect(store.entries.count == 2)
        #expect(store.entries[0].kind == .fatigue)
        #expect(store.entries[1].kind == .nausea)
    }

    @Test("Summary aggregates by kind with severity-weighted sort")
    func summaryAggregation() async throws {
        let repo = try makeRepo()
        let store = SideEffectsLogbookStore(medicationID: medID, repo: repo)
        // nausea ×3 mild = weight 3
        for _ in 0 ..< 3 {
            await store.log(loggedAt: .now, kind: .nausea, severity: 1, note: nil)
        }
        // fatigue ×1 severe = weight 3 but only 1 row — tied weight
        await store.log(loggedAt: .now, kind: .fatigue, severity: 3, note: nil)
        let summary = store.summaryByKind
        #expect(summary.count == 2)
        // Both have weight 3; ordering is unspecified for ties, but both
        // kinds must surface and counts must match.
        let kinds = Set(summary.map(\.kind))
        #expect(kinds == [.nausea, .fatigue])
        let nausea = try #require(summary.first { $0.kind == .nausea })
        #expect(nausea.count == 3)
        #expect(nausea.weight == 3)
        let fatigue = try #require(summary.first { $0.kind == .fatigue })
        #expect(fatigue.count == 1)
        #expect(fatigue.weight == 3)
    }

    @Test("entriesByDay buckets by calendar day, newest-day-first")
    func entriesByDayBucketing() async throws {
        let repo = try makeRepo()
        let store = SideEffectsLogbookStore(medicationID: medID, repo: repo)
        let calendar = Calendar.current
        // Anchor "today" to local noon so the `today - 1h` row below stays in
        // the same calendar day no matter the wall-clock time. Using
        // `Date.now` directly made this test fail in the 00:00–01:00 window
        // (the −1h row rolled back into yesterday's bucket).
        let today = try #require(calendar.date(bySettingHour: 12, minute: 0, second: 0, of: Date.now))
        let yesterday = try #require(calendar.date(byAdding: .day, value: -1, to: today))
        await store.log(loggedAt: yesterday, kind: .nausea, severity: 1, note: nil)
        await store.log(loggedAt: today, kind: .fatigue, severity: 1, note: nil)
        await store.log(
            loggedAt: today.addingTimeInterval(-3600),
            kind: .headache,
            severity: 1,
            note: nil
        )
        let groups = store.entriesByDay
        #expect(groups.count == 2)
        #expect(calendar.isDate(groups[0].day, inSameDayAs: today))
        #expect(groups[0].rows.count == 2)
        #expect(groups[0].rows[0].kind == .fatigue)
        #expect(groups[0].rows[1].kind == .headache)
        #expect(calendar.isDate(groups[1].day, inSameDayAs: yesterday))
        #expect(groups[1].rows.count == 1)
    }

    @Test("Delete removes the row from state")
    func deleteRemoves() async throws {
        let repo = try makeRepo()
        let store = SideEffectsLogbookStore(medicationID: medID, repo: repo)
        await store.log(loggedAt: .now, kind: .nausea, severity: 1, note: nil)
        let id = try #require(store.entries.first?.id)
        await store.delete(id: id)
        #expect(store.entries.isEmpty)
    }

    @Test("Severity clamped at repo boundary surfaces clamped value")
    func severityClamp() async throws {
        let repo = try makeRepo()
        let store = SideEffectsLogbookStore(medicationID: medID, repo: repo)
        await store.log(loggedAt: .now, kind: .nausea, severity: 99, note: nil)
        #expect(store.entries.first?.severity == 3)
    }

    @Test("Severity tone helper maps to badge tones")
    func severityToneHelper() {
        #expect(SideEffectsLogbookSection.severityTone(weight: 0, count: 0) == .neutral)
        #expect(SideEffectsLogbookSection.severityTone(weight: 3, count: 3) == .neutral) // avg 1.0
        #expect(SideEffectsLogbookSection.severityTone(weight: 6, count: 3) == .warning) // avg 2.0
        #expect(SideEffectsLogbookSection.severityTone(weight: 9, count: 3) == .critical) // avg 3.0
    }

    @Test("Window filter excludes rows outside the loaded sinceDays")
    func windowFilter() async throws {
        let repo = try makeRepo()
        let store = SideEffectsLogbookStore(medicationID: medID, repo: repo, windowDays: 7)
        let now = Date.now
        let oldDate = try #require(Calendar.current.date(byAdding: .day, value: -30, to: now))
        await store.log(loggedAt: oldDate, kind: .nausea, severity: 1, note: nil)
        await store.log(loggedAt: now, kind: .fatigue, severity: 1, note: nil)
        // `log` populates `entries` directly with sort-by-loggedAt — both
        // rows surface in the in-memory state right after insert. But
        // explicit `load()` re-applies the 7-day window.
        await store.load()
        #expect(store.entries.count == 1)
        #expect(store.entries.first?.kind == .fatigue)
    }
}
