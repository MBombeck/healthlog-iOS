import Foundation
@testable import HealthLog
import Testing

/// **W-TZ-MED (v0.15.2) — Verlauf glyph track buckets on the profile zone.**
///
/// `MedicationDetailStore.verlaufGlyphs()` reduces each server dose-history row
/// into a calendar day for the 14/90-day glyph track. Pre-fix that bucketing
/// used `Calendar.current` (the DEVICE timezone), so a traveling user (device
/// TZ ≠ profile TZ) saw a dose attributed to the wrong day near a midnight
/// boundary — the same west-of-UTC adherence-misattribution class already
/// closed on `ComplianceReconciler` / `MedicationDayKey` / the today-window.
///
/// These tests prove the store's NO-ARG `verlaufGlyphs()` now defaults its
/// bucketing calendar to the injected `profileTimeZoneProvider` zone, that an
/// explicit `calendar` still overrides (unit-test escape hatch + non-regression
/// for `device == profile`), and that a nil/unknown profile zone falls back to
/// the device TZ without crashing. Mirrors the assertion style of
/// `ComplianceReconcilerProfileTZTests` (HOME-5 DOSE-SAFETY).
@MainActor
@Suite("MedicationDetailStore — profile-tz Verlauf bucketing (W-TZ-MED)")
struct MedicationDetailStoreProfileTZTests {
    /// Fixed instant: 2023-11-21 09:00 UTC. Chosen so a single ledger row 23 h
    /// earlier (2023-11-20 10:00 UTC) lands on DIFFERENT calendar days in two
    /// well-separated zones — the heart of the traveler seam.
    private let now = Date(timeIntervalSince1970: 1_700_557_200)

    /// Far-east zone (UTC+13, no DST in November) — a late-evening-UTC instant
    /// is already "tomorrow" here.
    private func east() throws -> TimeZone {
        try #require(TimeZone(identifier: "Pacific/Tongatapu"))
    }

    /// Far-west zone (UTC-10, no DST) — the same instant is still "today".
    private func west() throws -> TimeZone {
        try #require(TimeZone(identifier: "Pacific/Honolulu"))
    }

    private func calendar(_ zone: TimeZone) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        return cal
    }

    private func envelope(rows: [MedicationDoseHistoryRow]) -> MedicationDoseHistoryEnvelope {
        MedicationDoseHistoryEnvelope(
            from: now.addingTimeInterval(-90 * 24 * 60 * 60),
            to: now,
            family: "daily",
            hasExpectedSlots: true,
            rows: rows
        )
    }

    /// A graded ledger slot at the exact instant `at`.
    private func slotRow(at: Date, status: String) -> MedicationDoseHistoryRow {
        MedicationDoseHistoryRow(
            kind: "slot",
            at: at,
            timeOfDay: "22:00",
            statusRaw: status,
            intake: .init(
                id: "evt-\(at.timeIntervalSince1970)",
                scheduledFor: at,
                takenAt: status.hasPrefix("taken") ? at : nil,
                skipped: false,
                autoMissed: status == "missed"
            )
        )
    }

    private func makeStore(
        rows: [MedicationDoseHistoryRow],
        profileTimeZoneProvider: @escaping () -> TimeZone
    ) -> MedicationDetailStore {
        let medication = Medication(
            id: "med-1",
            name: "Lisinopril",
            dose: "5 mg",
            schedule: MedicationSchedule(times: [TimeOfDay(hour: 22, minute: 0)])
        )
        let api = ProfileTZStubAPIClient()
        // swiftlint:disable:next force_try
        let outbox = try! OutboxQueue(inMemory: true)
        let repo = MedicationsRepository(api: api, outbox: outbox)
        let store = MedicationDetailStore(
            medication: medication,
            repo: repo,
            profileTimeZoneProvider: profileTimeZoneProvider
        )
        store._testInject(intakes: [], doseHistory: envelope(rows: rows))
        return store
    }

    /// The default (no-arg `calendar`) `verlaufGlyphs()` must bucket on the
    /// injected profile zone, NOT the device TZ. Proof: a row at 2023-11-13
    /// 22:00 UTC is "today" (offset 0) in the west zone but "yesterday" (offset
    /// 1) in the east zone — relative to the SAME `now`. The glyph lands in the
    /// position the PROFILE calendar dictates.
    @Test("no-arg verlaufGlyphs buckets the row into the profile-tz day")
    func defaultBucketsOnProfileZone() throws {
        let west = try west()
        let east = try east()
        // 2023-11-20T10:00:00Z. West (UTC-10): 2023-11-20 00:00 → SAME day as
        // `now` (2023-11-20 23:00 west) → offset 0. East (UTC+13): 2023-11-20
        // 23:00 vs now 2023-11-21 22:00 → offset 1 (yesterday). The same instant
        // buckets into a different profile-tz day east vs west — the seam.
        let rowAt = Date(timeIntervalSince1970: 1_700_474_400)

        let westStore = makeStore(rows: [slotRow(at: rowAt, status: "taken_on_time")], profileTimeZoneProvider: { west })
        let westGlyphs = westStore.verlaufGlyphs(days: 4, now: now)
        // Cross-check against an explicit west calendar — the no-arg default
        // must equal it.
        let westExplicit = westStore.verlaufGlyphs(days: 4, now: now, calendar: calendar(west))
        #expect(westGlyphs == westExplicit, "no-arg default must bucket on the profile (west) zone")

        let eastStore = makeStore(rows: [slotRow(at: rowAt, status: "taken_on_time")], profileTimeZoneProvider: { east })
        let eastGlyphs = eastStore.verlaufGlyphs(days: 4, now: now)
        let eastExplicit = eastStore.verlaufGlyphs(days: 4, now: now, calendar: calendar(east))
        #expect(eastGlyphs == eastExplicit, "no-arg default must bucket on the profile (east) zone")

        // The two zones disagree on WHICH day the row belongs to — that is the
        // whole point. Locate the `.onTime` glyph (its day index) in each.
        let westIdx = westGlyphs.firstIndex(of: .onTime)
        let eastIdx = eastGlyphs.firstIndex(of: .onTime)
        #expect(westIdx != nil && eastIdx != nil, "both zones must place the graded row somewhere in the window")
        #expect(westIdx != eastIdx, "the same instant must land on different profile-tz days east vs west")
    }

    /// Non-regression: when `device == profile`, the result is byte-identical to
    /// the pre-fix behaviour (an explicit device calendar). We model this by
    /// pointing the provider at a fixed zone and asserting the no-arg default
    /// equals the explicit same-zone call — i.e. the override path and the
    /// default path agree when they reference the same zone.
    @Test("explicit calendar overrides the profile default (device == profile non-regression)")
    func explicitCalendarOverridesDefault() throws {
        let west = try west()
        let east = try east()
        // 2023-11-20T10:00:00Z. Buckets into a different profile-tz day east vs
        // west (see `defaultBucketsOnProfileZone`).
        let rowAt = Date(timeIntervalSince1970: 1_700_474_400)
        // Profile zone = east, but the caller passes an explicit WEST calendar.
        let store = makeStore(rows: [slotRow(at: rowAt, status: "taken_on_time")], profileTimeZoneProvider: { east })
        let viaProfileDefault = store.verlaufGlyphs(days: 4, now: now)
        let viaExplicitWest = store.verlaufGlyphs(days: 4, now: now, calendar: calendar(west))
        // Explicit west calendar wins over the east profile default — they
        // disagree on the row's day, proving the explicit arg is honoured.
        #expect(
            viaProfileDefault != viaExplicitWest,
            "an explicit calendar must override the profile-tz default"
        )
        // And the explicit-west call equals what a west-profile store produces
        // by default — confirming the override fully replaces the zone.
        let westStore = makeStore(rows: [slotRow(at: rowAt, status: "taken_on_time")], profileTimeZoneProvider: { west })
        #expect(viaExplicitWest == westStore.verlaufGlyphs(days: 4, now: now))
    }

    /// A nil/unknown profile zone (provider returns `.current`) must fall back
    /// to the device TZ without crashing — preserving pre-fix behaviour for the
    /// non-traveler. The default provider IS `.current`, so the no-arg call must
    /// equal an explicit `.current` calendar.
    @Test("default .current provider falls back to device TZ (no crash, no regression)")
    func currentProviderFallsBackToDeviceTZ() throws {
        let rowAt = now.addingTimeInterval(-24 * 60 * 60)
        let medication = Medication(
            id: "med-1",
            name: "Lisinopril",
            dose: "5 mg",
            schedule: MedicationSchedule(times: [TimeOfDay(hour: 8, minute: 0)])
        )
        let api = ProfileTZStubAPIClient()
        // swiftlint:disable:next force_try
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MedicationsRepository(api: api, outbox: outbox)
        // No profileTimeZoneProvider passed → defaults to `{ .current }`.
        let store = MedicationDetailStore(medication: medication, repo: repo)
        store._testInject(intakes: [], doseHistory: envelope(rows: [slotRow(at: rowAt, status: "taken_on_time")]))

        let viaDefault = store.verlaufGlyphs(days: 4, now: now)
        let viaExplicitCurrent = store.verlaufGlyphs(days: 4, now: now, calendar: calendar(.current))
        #expect(viaDefault == viaExplicitCurrent, "nil/unknown profile zone → device-TZ (.current) fallback")
    }
}

/// Inert client — these are pure-derivation tests; the store is hydrated via
/// `_testInject`, so no network call should ever fire.
private final class ProfileTZStubAPIClient: APIClientProtocol, @unchecked Sendable {
    func send<T: Decodable & Sendable>(_: APIRequest<T>) async throws -> T {
        throw HLError.server(status: 404, code: "NOT_FOUND", message: "no route")
    }

    func sendVoid(_: APIRequest<EmptyPayload>) async throws {
        throw HLError.server(status: 404, code: "NOT_FOUND", message: "no route")
    }

    func download(_: APIRequest<Data>) async throws -> (Data, HTTPURLResponse) {
        throw HLError.server(status: 404, code: "NOT_FOUND", message: "no route")
    }
}
