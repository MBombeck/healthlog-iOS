import Foundation
@testable import HealthLog
import Testing

/// **REG-4 (2026-05-21).** Build-23 TestFlight walkthrough surfaced two
/// linked complaints about the compliance heatmap: (a) "ist mir zu hoch
/// und zu wenige Punkte" — sparse 8-week × 7-day matrix on a wide card
/// reads as a half-empty footprint; (b) "erst bei mehr als drei Monaten
/// das Ding überhaupt erst anzeigen und dann auch für zwölf Wochen
/// anzeigen". The fix bumps the grid to 12 × 7 = 84 cells and gates the
/// section behind a 90-day pre-roll so freshly-onboarded users see no
/// heatmap until the data is dense enough to feel honest.
///
/// These tests lock the gate contract (≥ 90 d window-span before render)
/// + the grid arity (12 × 7) so a regression on either side trips the
/// suite before TestFlight.
@Suite("ComplianceHeatmapSection — REG-4 gate + 12×7 arity")
struct ComplianceHeatmapSectionTests {
    private let now = Date(timeIntervalSince1970: 1_715_990_400) // 2024-05-18T00:00:00Z

    // MARK: - 90-day pre-roll gate

    @Test("Empty days array fails the 90-day gate (renders EmptyView)")
    func emptyDaysFailsGate() {
        #expect(
            ComplianceHeatmapSection.hasEnoughHistory(in: [], now: now) == false
        )
    }

    @Test("Single day of history fails the 90-day gate")
    func singleDayFailsGate() {
        let days = [
            ComplianceDay(date: now, scheduled: 2, taken: 2)
        ]
        #expect(
            ComplianceHeatmapSection.hasEnoughHistory(in: days, now: now) == false
        )
    }

    @Test("Exactly 89 days of history fails the 90-day gate (off-by-one boundary)")
    func eightyNineDaysFailsGate() throws {
        let earliest = try #require(
            Calendar.current.date(byAdding: .day, value: -89, to: now)
        )
        let days = [
            ComplianceDay(date: earliest, scheduled: 1, taken: 1),
            ComplianceDay(date: now, scheduled: 1, taken: 1)
        ]
        #expect(
            ComplianceHeatmapSection.hasEnoughHistory(in: days, now: now) == false
        )
    }

    @Test("Exactly 90 days of history passes the gate (renders 12×7 grid)")
    func ninetyDaysPassesGate() throws {
        let earliest = try #require(
            Calendar.current.date(byAdding: .day, value: -90, to: now)
        )
        let days = [
            ComplianceDay(date: earliest, scheduled: 1, taken: 1),
            ComplianceDay(date: now, scheduled: 1, taken: 1)
        ]
        #expect(
            ComplianceHeatmapSection.hasEnoughHistory(in: days, now: now) == true
        )
    }

    @Test("84 days of data-bearing history — the default 12×7 footprint — still fails the 90-day gate")
    func storeWindowAloneFailsGate() throws {
        // Worth locking explicitly: 84 data-bearing days (= the default
        // 12-week footprint) is one short of the gate. The gate's pass
        // condition is the earliest DATA-BEARING day being ≥ 90 d old —
        // i.e. the **user** must have ≥ 90 d of schedule tenure, not
        // merely a wide window available. This sentinel guards against a
        // store-window bump (#13 raised it to 182 d for the 26-week pick)
        // silently flipping the gate semantics from "user-tenure ≥ 90 d"
        // to "store-window ≥ 90 d", which would re-open the broken-chart
        // vector on sparse-data devices.
        var days: [ComplianceDay] = []
        for offset in 0 ..< 84 {
            let date = try #require(
                Calendar.current.date(byAdding: .day, value: -offset, to: now)
            )
            days.append(ComplianceDay(date: date, scheduled: 1, taken: 1))
        }
        #expect(
            ComplianceHeatmapSection.hasEnoughHistory(in: days, now: now) == false
        )
    }

    @Test("Long-tenure user with 120 days of history passes the gate")
    func longTenurePassesGate() throws {
        var days: [ComplianceDay] = []
        for offset in 0 ..< 120 {
            let date = try #require(
                Calendar.current.date(byAdding: .day, value: -offset, to: now)
            )
            days.append(ComplianceDay(date: date, scheduled: 1, taken: 1))
        }
        #expect(
            ComplianceHeatmapSection.hasEnoughHistory(in: days, now: now) == true
        )
    }

    @Test("Gate uses the **oldest** date, not the count — a sparse 90-day-old single entry still passes")
    func sparseSingleDayPassesGate() throws {
        // Confirms the predicate is span-based, not count-based: one
        // intake recorded 90 d ago + no others in between still flips
        // the gate to true. Pragmatically, the user has been around long
        // enough that the grid will look populated *enough* once SWR
        // backfills today's slice.
        let earliest = try #require(
            Calendar.current.date(byAdding: .day, value: -90, to: now)
        )
        let days = [ComplianceDay(date: earliest, scheduled: 1, taken: 1)]
        #expect(
            ComplianceHeatmapSection.hasEnoughHistory(in: days, now: now) == true
        )
    }

    // MARK: - #13 — zero-bucket padding must not satisfy the gate

    @Test("Server-style zero buckets (scheduled == 0, taken == 0) do not count as history")
    func zeroBucketsFailGate() throws {
        // Server v1.15.9 emits a bucket for EVERY day of the requested
        // window — zero days included. A fresh user on the 182-day window
        // therefore receives rows reaching 181 days back; only days that
        // actually carry schedule data may anchor the tenure gate, or the
        // REG-4 broken-chart vector re-opens for brand-new users.
        var days: [ComplianceDay] = []
        for offset in 0 ..< 182 {
            let date = try #require(
                Calendar.current.date(byAdding: .day, value: -offset, to: now)
            )
            // Only the last 10 days carry real schedule data.
            let scheduled = offset < 10 ? 1 : 0
            days.append(ComplianceDay(date: date, scheduled: scheduled, taken: scheduled))
        }
        #expect(
            ComplianceHeatmapSection.hasEnoughHistory(in: days, now: now) == false,
            "181 days of zero-padding + 10 days of data is 10 days of tenure, not 181"
        )
    }

    @Test("Zero-padded window with ≥ 90 d of data-bearing days passes the gate")
    func zeroPaddedLongTenurePassesGate() throws {
        var days: [ComplianceDay] = []
        for offset in 0 ..< 182 {
            let date = try #require(
                Calendar.current.date(byAdding: .day, value: -offset, to: now)
            )
            let scheduled = offset <= 90 ? 1 : 0
            days.append(ComplianceDay(date: date, scheduled: scheduled, taken: scheduled))
        }
        #expect(
            ComplianceHeatmapSection.hasEnoughHistory(in: days, now: now) == true
        )
    }

    // MARK: - Grid arity (REG-4 spec; #13 default)

    @Test("Default grid arity is 12 weeks × 7 days = 84 cells")
    func gridArityDefaultsTo12x7() {
        #expect(ComplianceHeatmapSection.defaultWeeksCount == 12)
        #expect(ComplianceHeatmapSection.daysPerWeekCount == 7)
        #expect(
            ComplianceHeatmapSection.defaultWeeksCount
                * ComplianceHeatmapSection.daysPerWeekCount == 84
        )
    }

    // MARK: - #13 — operator-selectable window

    @Test("Window options are exactly 4 / 8 / 12 / 26 weeks")
    func windowOptions() {
        #expect(ComplianceHeatmapWeeks.allCases.map(\.rawValue) == [4, 8, 12, 26])
    }

    @Test("The store-side data window covers the largest pick (26 weeks = 182 days)")
    func dataWindowCoversLargestPick() {
        let maxWeeks = ComplianceHeatmapWeeks.allCases.map(\.rawValue).max() ?? 0
        #expect(
            MedicationsStore.complianceDaysWindow >= maxWeeks * 7,
            "every pick must render fully populated from the one cached payload"
        )
    }
}

/// **#13 (2026-06-11).** The heatmap window length is an operator-facing
/// UI-pref on `SettingsStore` (Settings → Erscheinungsbild). These tests lock
/// the UserDefaults round-trip + the 12-week default so a fresh install (and
/// every pre-#13 install, whose key is unset) keeps the REG-4 footprint.
@MainActor
@Suite("SettingsStore — #13 complianceHeatmapWeeks UI-pref")
struct ComplianceHeatmapWeeksPrefTests {
    private static func makeDefaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "hl.tests.heatmapWeeks.\(UUID().uuidString)"))
    }

    private static func makeStore(defaults: UserDefaults) -> SettingsStore {
        SettingsStore(repo: SettingsRepository(api: StubAPIClient()), defaults: defaults)
    }

    @Test("defaults to 12 weeks when the key is unset (fresh + pre-#13 installs)")
    func defaultsToTwelve() throws {
        let store = try Self.makeStore(defaults: Self.makeDefaults())
        #expect(store.complianceHeatmapWeeks == .twelve)
    }

    @Test("round-trips every option through UserDefaults", arguments: ComplianceHeatmapWeeks.allCases)
    func roundTrips(option: ComplianceHeatmapWeeks) throws {
        let defaults = try Self.makeDefaults()
        let store = Self.makeStore(defaults: defaults)
        store.complianceHeatmapWeeks = option
        // A second store over the same suite must hydrate the persisted pick.
        let rehydrated = Self.makeStore(defaults: defaults)
        #expect(rehydrated.complianceHeatmapWeeks == option)
    }

    @Test("a corrupt persisted value falls back to the 12-week default")
    func corruptValueFallsBack() throws {
        let defaults = try Self.makeDefaults()
        defaults.set(7, forKey: "hl.settings.complianceHeatmap.weeks")
        let store = Self.makeStore(defaults: defaults)
        #expect(store.complianceHeatmapWeeks == .twelve)
    }
}

/// **v0.8.3 W-B (2026-05-29).** The compliance heatmap was recoloured from
/// the v0.8.2 W3a monochrome `statusOK`-opacity density ramp to the app's
/// green/yellow/red STATUS semantics (operator decision, intentionally
/// supersedes W3a for THIS surface) so the aggregate heatmap reads
/// coherently with the per-medication 90-day adherence track.
///
/// These tests lock the per-day worst-status-wins mapping
/// (`ComplianceStatusPalette.status(for:)`): full → taken, partial →
/// partial, none-but-scheduled → missed, no-schedule/no-data → none.
@Suite("ComplianceStatusPalette — W-B green/yellow/red worst-status-wins")
struct ComplianceStatusPaletteTests {
    private let day = Date(timeIntervalSince1970: 1_715_990_400)

    @Test("nil day (slot outside data window) maps to .none")
    func nilDayIsNone() {
        #expect(ComplianceStatusPalette.status(for: nil) == .none)
    }

    @Test("scheduled == 0 (off-day, no doses due) maps to .none, not green")
    func noScheduleIsNone() {
        let d = ComplianceDay(date: day, scheduled: 0, taken: 0)
        #expect(ComplianceStatusPalette.status(for: d) == .none)
    }

    @Test("all due doses taken maps to .taken (green)")
    func fullyTakenIsTaken() {
        #expect(ComplianceStatusPalette.status(for: ComplianceDay(date: day, scheduled: 2, taken: 2)) == .taken)
        #expect(ComplianceStatusPalette.status(for: ComplianceDay(date: day, scheduled: 1, taken: 1)) == .taken)
    }

    @Test("partial — one of two doses missed — maps to .partial (yellow), worst-status-wins")
    func partialIsPartial() {
        let d = ComplianceDay(date: day, scheduled: 2, taken: 1)
        #expect(ComplianceStatusPalette.status(for: d) == .partial)
    }

    @Test("every due dose missed maps to .missed (red)")
    func fullyMissedIsMissed() {
        let d = ComplianceDay(date: day, scheduled: 3, taken: 0)
        #expect(ComplianceStatusPalette.status(for: d) == .missed)
    }

    @Test("taken exceeding scheduled (PRN over-take) still reads .taken")
    func overTakeIsTaken() {
        let d = ComplianceDay(date: day, scheduled: 1, taken: 2)
        #expect(ComplianceStatusPalette.status(for: d) == .taken)
    }
}
