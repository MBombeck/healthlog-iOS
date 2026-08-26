import AppIntents
import Foundation
@testable import HealthLog
import Testing

/// **v0.8.4 WWIDGET-3** — coverage for the compliance READ intent.
///
/// Two layers:
///   - ``ComplianceQueryCopy/resource(scheduled:taken:)`` — the pure
///     scheduled/taken → spoken-summary mapping (rest-day / complete /
///     partial buckets + defensive clamping). No perform, no I/O.
///   - ``MedicationComplianceQueryIntent/perform()`` — the snapshot fast
///     path and the server-first backstop, using a stub `APIClient` + an
///     in-memory `WidgetSnapshotStore` override so the read runs the real
///     resolver path without a network or the live App Group container.
@Suite("Medication compliance query intent")
@MainActor
struct MedicationComplianceQueryIntentTests {
    // MARK: - Pure summary mapping

    /// Render the resource to its final string under a **forced** locale so
    /// the assertions are deterministic regardless of the test host's
    /// language — the catalogue now ships DE, so a bare `String(localized:)`
    /// would resolve to whichever locale the simulator runs in.
    private func rendered(scheduled: Int, taken: Int, locale: Locale = Locale(identifier: "en")) -> String {
        var resource = ComplianceQueryCopy.resource(scheduled: scheduled, taken: taken)
        resource.locale = locale
        return String(localized: resource)
    }

    @Test("Rest day (nothing scheduled) reads as a no-doses line")
    func restDayCopy() {
        #expect(rendered(scheduled: 0, taken: 0) == "You have no doses scheduled for today.")
    }

    @Test("All taken reads as the complete line")
    func allTakenCopy() {
        #expect(rendered(scheduled: 3, taken: 3) == "You’ve taken all 3 of today’s doses.")
    }

    @Test("Partial reads as the remaining line, counts substituted in order")
    func partialCopy() {
        #expect(rendered(scheduled: 4, taken: 1) == "You’ve taken 1 of 4 doses today.")
    }

    @Test("Partial line's format key matches the localized catalogue entry")
    func partialCopyKeyMatchesCatalogue() {
        // The generated key must equal the xcstrings key the DE translation is
        // filed under, otherwise the German string would never bind. Both
        // languages keep the "taken, then scheduled" order so the two
        // non-positional %lld slots line up. Asserting the key is locale-
        // independent (unlike a rendered DE string, which depends on the test
        // host's resolved bundle).
        let key = ComplianceQueryCopy.resource(scheduled: 4, taken: 1).key
        #expect(key == "You’ve taken %lld of %lld doses today.")
    }

    @Test("Over-count clamps so taken never exceeds scheduled")
    func overCountClampsToComplete() {
        // A transient out-of-range snapshot (taken > scheduled) must read as
        // "all taken", never "5 of 3".
        #expect(rendered(scheduled: 3, taken: 5) == "You’ve taken all 3 of today’s doses.")
    }

    @Test("Negative counts floor to zero / rest-day")
    func negativeFloorsToRestDay() {
        #expect(rendered(scheduled: -2, taken: -1) == "You have no doses scheduled for today.")
    }

    // MARK: - perform(): snapshot fast path

    @Test("Signed-out surfaces the sign-in dialog, no fetch")
    func signedOutGate() async throws {
        let (api, _) = try installOverride(signedIn: false, apiBehaviour: .succeed)
        defer { teardown() }

        _ = try await MedicationComplianceQueryIntent().perform()
        #expect(await api.sentPaths.isEmpty)
    }

    @Test("Reads the App Group snapshot first — no server fetch")
    func snapshotFastPath() async throws {
        let (api, _) = try installOverride(signedIn: true, apiBehaviour: .succeed)
        defer { teardown() }

        let store = makeStore()
        try store.write(
            WidgetSnapshot(
                nextDose: nil,
                compliance: WidgetSnapshot.ComplianceSummary(scheduled: 4, taken: 2),
                generatedAt: .now
            )
        )
        MedicationComplianceQueryIntent.snapshotStoreOverride = store

        _ = try await MedicationComplianceQueryIntent().perform()
        // Fast path: the snapshot answered, the server was never asked.
        #expect(await api.sentPaths.isEmpty)
    }

    @Test("Falls back to a server-first compliance fetch when no snapshot")
    func serverBackstop() async throws {
        let (api, _) = try installOverride(signedIn: true, apiBehaviour: .succeed)
        defer { teardown() }

        // Empty snapshot store (placeholder → distantPast → treated as no data).
        MedicationComplianceQueryIntent.snapshotStoreOverride = makeStore()

        _ = try await MedicationComplianceQueryIntent().perform()
        #expect(await api.sentPaths == ["/api/medications/intake"])
    }

    @Test("Server unreachable + no snapshot surfaces the soft unavailable line")
    func serverOfflineSoftFails() async throws {
        _ = try installOverride(signedIn: true, apiBehaviour: .offline)
        defer { teardown() }

        MedicationComplianceQueryIntent.snapshotStoreOverride = makeStore()

        // Must not throw — a read intent degrades to a dialog, never an error.
        _ = try await MedicationComplianceQueryIntent().perform()
    }

    // MARK: - Harness

    private func makeStore() -> WidgetSnapshotStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("compliance-snapshot-\(UUID().uuidString).json")
        return WidgetSnapshotStore(url: url)
    }

    private func installOverride(
        signedIn: Bool,
        apiBehaviour: ComplianceStubAPIClient.Behaviour
    ) throws -> (api: ComplianceStubAPIClient, outbox: OutboxQueue) {
        let keychain = InMemoryKeychain()
        if signedIn {
            try keychain.setString("test-bearer", forKey: KeychainKey.authToken)
        }
        let api = ComplianceStubAPIClient(behaviour: apiBehaviour)
        let outbox = try OutboxQueue(inMemory: true)
        IntentDependencies.testOverride = IntentDependencies.Resolved(
            keychain: keychain,
            api: api,
            outbox: outbox,
            measurementsRepo: MeasurementsRepository(api: api, outbox: outbox),
            medicationsRepo: MedicationsRepository(api: api, outbox: outbox),
            moodRepo: MoodRepository(api: api, outbox: outbox)
        )
        return (api, outbox)
    }

    private func teardown() {
        IntentDependencies.testOverride = nil
        MedicationComplianceQueryIntent.snapshotStoreOverride = nil
    }
}

/// **M1 (AUDIT-bugs b198)** — `ComplianceDayMatcher` must resolve "today" for a
/// server day-key whose `.date` is UTC-midnight (`JSONDecoder.hlDayKey`), even
/// for a user west of UTC, AND for a standalone day-key at local midnight.
@Suite("ComplianceDayMatcher — timezone-robust today resolution (M1)")
struct ComplianceDayMatcherTests {
    private func utcCalendar() -> Calendar {
        var c = Calendar(identifier: .iso8601)
        c.timeZone = .gmt
        return c
    }

    @Test("Server UTC-midnight day matches today for a user west of UTC (Americas)")
    func utcMidnightDayMatchesWestOfUTC() throws {
        // `now` = 2026-06-19T03:00:00Z. In Los Angeles (UTC-7/8) the local
        // calendar day is still 2026-06-18, but the server's compliance day-key
        // for "today" is the UTC date 2026-06-19 at UTC-midnight. The naive
        // `Calendar.current.isDateInToday(utcMidnight)` would MISS that day for a
        // west-of-UTC host; the matcher's UTC arm must catch it.
        let now = try #require(ISO8601DateFormatter().date(from: "2026-06-19T03:00:00Z"))
        let utcMidnightToday = utcCalendar().startOfDay(for: now) // 2026-06-19 00:00 UTC
        let yesterday = utcMidnightToday.addingTimeInterval(-86400)

        let days = [
            ComplianceDay(date: yesterday, scheduled: 2, taken: 2),
            ComplianceDay(date: utcMidnightToday, scheduled: 3, taken: 1)
        ]

        let match = ComplianceDayMatcher.today(in: days, now: now)
        #expect(match?.date == utcMidnightToday)
        #expect(match?.taken == 1, "Must pick today's UTC row (1 taken), not yesterday's")
    }

    @Test("Standalone local-midnight day matches today")
    func localMidnightDayMatches() {
        let now = Date.now
        let localMidnightToday = Calendar.current.startOfDay(for: now)
        let days = [ComplianceDay(date: localMidnightToday, scheduled: 1, taken: 1)]
        let match = ComplianceDayMatcher.today(in: days, now: now)
        #expect(match?.date == localMidnightToday)
    }

    @Test("No matching day returns nil (caller falls back to days.last)")
    func noTodayReturnsNil() throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-06-19T03:00:00Z"))
        let utcMidnightToday = utcCalendar().startOfDay(for: now)
        let twoDaysAgo = utcMidnightToday.addingTimeInterval(-2 * 86400)
        let days = [ComplianceDay(date: twoDaysAgo, scheduled: 2, taken: 2)]
        #expect(ComplianceDayMatcher.today(in: days, now: now) == nil)
    }
}

/// Stub that records sent paths and answers `/api/medications/intake`
/// (compliance scope) with a single today `ComplianceDay`.
private actor ComplianceStubAPIClient: APIClientProtocol {
    enum Behaviour {
        case succeed
        case offline
    }

    private let behaviour: Behaviour
    private(set) var sentPaths: [String] = []

    init(behaviour: Behaviour) {
        self.behaviour = behaviour
    }

    func send<T: Decodable & Sendable>(_ request: APIRequest<T>) async throws -> T {
        sentPaths.append(request.path)
        switch behaviour {
        case .offline:
            throw HLError.offline
        case .succeed:
            return try Self.cannedResponse(for: request)
        }
    }

    func sendVoid(_ request: APIRequest<EmptyPayload>) async throws {
        sentPaths.append(request.path)
        if case .offline = behaviour { throw HLError.offline }
    }

    func download(_: APIRequest<Data>) async throws -> (Data, HTTPURLResponse) {
        throw HLError.unknown("download not stubbed")
    }

    private static func cannedResponse<T: Decodable>(for _: APIRequest<T>) throws -> T {
        // Today's compliance row: 3 scheduled, 2 taken.
        let iso = ISO8601DateFormatter().string(from: .now)
        let json = """
        [{"date":"\(iso)","scheduled":3,"taken":2}]
        """
        return try JSONDecoder.hlDefault.decode(T.self, from: Data(json.utf8))
    }
}
