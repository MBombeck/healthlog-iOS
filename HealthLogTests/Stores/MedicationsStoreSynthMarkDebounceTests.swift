import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// **v0.8.2 W1b (audit B5 + C6) — synth-mark in-flight guard + derived-count revert.**
///
/// B5: `MedicationsStore`'s synth-placeholder mark path is a server CREATE
/// (`recordFromReminder` → `POST /api/medications/intake/bulk`). Without an
/// in-flight guard, two rapid taps on the same scheduled dose fire two
/// concurrent CREATEs → two server intake rows for one dose. The store now
/// claims an in-flight slot keyed by the (stable) synth id synchronously
/// before the first `await`; a second tap while the first is pending is
/// coalesced.
///
/// C6: on a hard (non-retriable) failure of an optimistic synth mark,
/// `removeOptimisticSynth` drops the optimistic row. Because the dashboard
/// ring derives its widened count from `derivedTodayIntakes` (live), the
/// derived `ComplianceSnapshot.reconciled` count must revert too — not just
/// the list row.
///
/// Real `MedicationsRepository` against a stubbed `URLSession` per the
/// PROJECT_GUIDE.md anti-pattern rule (no mock server on intake/outbox paths).
@Suite("MedicationsStore — synth-mark debounce + derived revert (W1b)", .serialized)
struct MedicationsStoreSynthMarkDebounceTests {
    // MARK: - Fixtures

    /// A twice-daily medication whose schedule slots land on *today* (real
    /// `.now`), so `store.derivedTodayIntakes` synthesises placeholders the
    /// reconciler can count. The exact hours don't matter — only that they
    /// resolve to today's calendar day.
    private static func twiceDailyMed(id: String = "med-lisinopril") -> Medication {
        Medication(
            id: id,
            name: "Lisinopril",
            dose: "5 mg",
            schedule: MedicationSchedule(times: [
                TimeOfDay(hour: 8, minute: 0),
                TimeOfDay(hour: 20, minute: 0)
            ]),
            active: true
        )
    }

    /// Stable synth id for the medication's first slot *today* (08:00).
    private static func firstSlotSynthID(medicationID: String) -> String {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: .now)
        let scheduledAt = calendar.date(
            bySettingHour: 8,
            minute: 0,
            second: 0,
            of: startOfToday
        )!
        return MedicationIntake.synthesizedPlaceholderID(
            medicationId: medicationID,
            scheduledAt: scheduledAt
        )
    }

    private func makeAPI() -> APIClient {
        let keychain = InMemoryKeychain()
        try? keychain.setString("token", forKey: KeychainKey.authToken)
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.8.2",
            buildNumber: "79"
        )
        return APIClient(
            environment: env,
            keychain: keychain,
            sessionConfiguration: .mock()
        )
    }

    private static func ok(_ request: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
    }

    private static func status(_ code: Int, request: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!,
            statusCode: code,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
    }

    private static let bulkSuccessBody = Data(#"""
    {"data":{"processed":1,"inserted":1,"duplicates":0,"entries":[{"index":0,"status":"inserted","id":"server-intake-42","reason":null}]}}
    """#.utf8)

    // MARK: - B5(a) — two rapid synth marks → exactly ONE create

    @Test("two rapid synth marks for one scheduled dose hit the bulk-create endpoint exactly once")
    @MainActor
    func rapidDoubleSynthMarkCreatesOnce() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        let counter = BulkCreateCounter()
        // Hold the first request open until both marks have been
        // dispatched, so the second tap genuinely overlaps the first
        // in-flight CREATE (proving the guard, not just serialisation).
        let gate = AsyncGate()
        MockURLProtocol.handler = { req in
            if req.url?.path == "/api/medications/intake/bulk" {
                counter.increment()
                gate.wait()
            }
            return (Self.ok(req), Self.bulkSuccessBody)
        }
        let repo = MedicationsRepository(api: api, outbox: outbox)
        let store = MedicationsStore(repo: repo)

        let med = Self.twiceDailyMed()
        store._testForceSet(medications: [med])
        let synthID = Self.firstSlotSynthID(medicationID: med.id)

        // Fire both marks; the first claims the in-flight slot and blocks
        // on the gate, the second must be coalesced by the guard.
        async let first = store.markIntakeQuick(intakeId: synthID, status: .taken)
        async let second = store.markIntakeQuick(intakeId: synthID, status: .taken)

        // Let both reach the store + the guard arbitration before
        // releasing the network.
        try await Task.sleep(nanoseconds: 50_000_000)
        gate.open()
        let outcomes = await [first, second]

        #expect(outcomes.allSatisfy { $0 == .success })
        #expect(
            counter.value == 1,
            "Rapid double synth-mark must produce exactly ONE bulk CREATE, got \(counter.value)"
        )
    }

    // MARK: - B5 — sequential re-tap after settle is allowed (guard releases)

    @Test("a mark is allowed again after the prior mark settles (guard releases)")
    @MainActor
    func guardReleasesAfterSettle() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        let counter = BulkCreateCounter()
        MockURLProtocol.handler = { req in
            if req.url?.path == "/api/medications/intake/bulk" { counter.increment() }
            return (Self.ok(req), Self.bulkSuccessBody)
        }
        let repo = MedicationsRepository(api: api, outbox: outbox)
        let store = MedicationsStore(repo: repo)

        let med = Self.twiceDailyMed()
        store._testForceSet(medications: [med])
        let synthID = Self.firstSlotSynthID(medicationID: med.id)

        _ = await store.markIntakeQuick(intakeId: synthID, status: .taken)
        _ = await store.markIntakeQuick(intakeId: synthID, status: .taken)

        #expect(
            counter.value == 2,
            "Two fully-settled sequential marks should each create (the guard only coalesces concurrent taps)"
        )
        #expect(store.isMarking(intakeId: synthID) == false)
    }

    // MARK: - C6 — hard-failed optimistic synth mark reverts row AND derived count

    @Test("hard-failed synth mark reverts the optimistic row and the derived reconciled count")
    @MainActor
    func hardFailRevertsDerivedCount() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        MockURLProtocol.handler = { req in
            (Self.status(422, request: req), Data(#"{"error":"medication_not_found"}"#.utf8))
        }
        let repo = MedicationsRepository(api: api, outbox: outbox)
        let store = MedicationsStore(repo: repo)

        let med = Self.twiceDailyMed()
        store._testForceSet(medications: [med])
        let synthID = Self.firstSlotSynthID(medicationID: med.id)
        let activeIDs: Set<String> = [med.id]
        // Server reports nothing scheduled yet (the RED-window asymmetry
        // this whole synth path exists to paper over).
        let serverSnapshot = ComplianceSnapshot(scheduledToday: 0, takenToday: 0)

        // Baseline: two synth placeholders derived, none taken.
        let baseline = ComplianceSnapshot.reconciled(
            server: serverSnapshot,
            todayIntakes: store.derivedTodayIntakes,
            activeMedicationIDs: activeIDs,
            medicationsLoaded: true
        )
        #expect(baseline.takenToday == 0)
        #expect(baseline.scheduledToday == 2)

        let outcome = await store.markIntakeQuick(intakeId: synthID, status: .taken)

        if case .failed = outcome {
            // expected — non-retriable 422
        } else {
            Issue.record("Expected .failed, got \(outcome)")
        }

        // Row reverted.
        #expect(store.todayIntakes.contains(where: { $0.id == synthID }) == false)

        // Derived reconciled count reverted: the optimistic taken is gone,
        // the placeholder re-surfaces as pending → takenToday back to 0.
        let afterFail = ComplianceSnapshot.reconciled(
            server: serverSnapshot,
            todayIntakes: store.derivedTodayIntakes,
            activeMedicationIDs: activeIDs,
            medicationsLoaded: true
        )
        #expect(
            afterFail.takenToday == 0,
            "A hard-failed optimistic synth mark must revert the derived ring count, not leave it widened"
        )
        #expect(afterFail.scheduledToday == 2)
        // Guard released so a retry is possible.
        #expect(store.isMarking(intakeId: synthID) == false)
    }
}

/// Thread-safe counter for the `MockURLProtocol.handler` closure (invoked
/// off the test actor). Mirrors the `RequestObserver` pattern in
/// `MedicationsStoreSynthMarkTests` — a lock-backed class so Swift 6
/// strict concurrency accepts the cross-isolation capture without
/// `@unchecked` on the test struct itself.
private final class BulkCreateCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0

    func increment() {
        lock.withLock { _value += 1 }
    }

    var value: Int {
        lock.withLock { _value }
    }
}

/// Minimal one-shot gate so a stub handler can block the first request
/// until the test releases it — lets a second concurrent mark genuinely
/// overlap an in-flight CREATE. Backed by a condition so the wait is a
/// real blocking wait on URLSession's delegate queue (the handler runs in
/// a synchronous context there).
private final class AsyncGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var isOpen = false

    func open() {
        condition.lock()
        isOpen = true
        condition.broadcast()
        condition.unlock()
    }

    func wait() {
        condition.lock()
        while !isOpen {
            condition.wait()
        }
        condition.unlock()
    }
}

// swiftlint:enable force_unwrapping
