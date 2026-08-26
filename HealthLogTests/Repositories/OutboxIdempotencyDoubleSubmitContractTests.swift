import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// audit-v0162 CRITICAL-2 — generic idempotency double-submit contract.
///
/// The recurring bug class (v0157 M2 / v0158 H3 / v0160 #39): a retriable
/// failure followed by a (manual or automatic) retry MINTS A FRESH KEY, so the
/// server sees two distinct writes → a duplicate clinical row. Each *instance*
/// is now tested individually; nothing locked the *pattern* for the next new
/// outbox-backed create path.
///
/// This ONE parameterized contract locks the pattern across every outbox-backed
/// create kind: enqueue → replay fails retriably (503) → replay succeeds (200),
/// and assert
///   1. the persisted `Idempotency-Key` is **byte-identical** across the failed
///      and the succeeding attempt (never re-minted between retries), and
///   2. exactly ONE POST reaches the create route on success and the queue
///      drains to a single removed op — i.e. one server row, not two.
///
/// Real `APIClient` + `MockURLProtocol` (stub `URLSession`) per PROJECT_GUIDE.md — NO
/// mock server. The replay service is built with `attemptBackoff: 0` so the H1
/// back-off window never masks the second (success) pass.
///
/// `.serialized` — owns the process-global `MockURLProtocol.handler` per test
/// (audit-v0162 H2).
@Suite("Outbox idempotency double-submit contract", .serialized)
struct OutboxIdempotencyDoubleSubmitContractTests {
    /// The outbox-backed create kinds this contract covers. Each maps to a
    /// fixture (payload + create route + a server-true 2xx envelope).
    enum CreateKind: String, CaseIterable {
        case allergy
        case familyHistory
        case lab
        case mentalHealth
    }

    // MARK: - Fixtures

    private func makeAPI() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "1.25.0",
            buildNumber: "1"
        )
        return APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
    }

    /// Wire ALL four create-kind repos so a single replay service drains any
    /// parameterized kind. `attemptBackoff: 0` so the retriable-then-succeed
    /// second pass is never skipped by the audit-v0162 H1 back-off.
    private func makeReplay(api: APIClient, outbox: OutboxQueue) -> OutboxReplayService {
        OutboxReplayService(
            outbox: outbox,
            measurementsRepo: MeasurementsRepository(api: api, outbox: outbox),
            moodRepo: MoodRepository(api: api, outbox: outbox),
            medicationsRepo: MedicationsRepository(api: api, outbox: outbox),
            labsRepo: LabsRepository(api: api, outbox: outbox),
            allergiesRepo: AllergiesRepository(api: api, outbox: outbox),
            familyHistoryRepo: FamilyHistoryRepository(api: api, outbox: outbox),
            mentalHealthRepo: MentalHealthRepository(api: api, outbox: outbox),
            attemptBackoff: 0
        )
    }

    private struct Fixture {
        let opKind: OutboxQueue.Operation.Kind
        let payload: Data
        let createPath: String
        let successBody: Data
    }

    private func fixture(for kind: CreateKind) throws -> Fixture {
        let enc = JSONEncoder.hlDefault
        switch kind {
        case .allergy:
            let body = OutboxQueue.Payloads.CreateAllergy(body: AllergyCreate(substance: "Penicillin"))
            let resp = """
            {"data":{"id":"srv-a-1","substance":"Penicillin","category":"MEDICATION","type":"ALLERGY",\
            "severity":"SEVERE","status":"ACTIVE","onsetAt":null,"reaction":null,"note":null,\
            "createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z"}}
            """
            return try Fixture(
                opKind: .createAllergy,
                payload: enc.encode(body),
                createPath: "/api/allergies",
                successBody: Data(resp.utf8)
            )
        case .familyHistory:
            let body = OutboxQueue.Payloads.CreateFamilyHistory(
                body: FamilyHistoryCreate(relationship: .mother, condition: "Diabetes")
            )
            let resp = """
            {"data":{"id":"srv-f-1","relationship":"MOTHER","condition":"Diabetes","ageAtOnset":null,\
            "note":null,"createdAt":"","updatedAt":""}}
            """
            return try Fixture(
                opKind: .createFamilyHistory,
                payload: enc.encode(body),
                createPath: "/api/family-history",
                successBody: Data(resp.utf8)
            )
        case .lab:
            let body = OutboxQueue.Payloads.CreateLab(
                body: LabResultCreate(value: 5.4, takenAt: "2026-01-01T08:30:00Z")
            )
            let resp = """
            {"data":{"id":"srv-lab-1","biomarkerId":null,"panel":null,"analyte":"HbA1c",\
            "value":5.4,"unit":"%","referenceLow":4.0,"referenceHigh":6.0,\
            "takenAt":"2026-01-01T08:30:00Z","source":"MANUAL","hasNote":false,\
            "rangeStatus":"in-range","createdAt":"2026-01-01T08:30:00Z","updatedAt":"2026-01-01T08:30:00Z"}}
            """
            return try Fixture(
                opKind: .createLab,
                payload: enc.encode(body),
                createPath: "/api/labs",
                successBody: Data(resp.utf8)
            )
        case .mentalHealth:
            let body = OutboxQueue.Payloads.CreateMentalHealthAssessment(
                body: CreateAssessmentRequest(
                    instrument: .phq9,
                    items: Array(repeating: 0, count: 9),
                    locale: "en",
                    source: "IOS",
                    externalId: "ext-mh-contract-1"
                )
            )
            let resp = """
            {"data":{"assessment":{"id":"srv-mh-1","instrument":"PHQ9","locale":"en","version":"standard",\
            "totalScore":0,"severityBand":"minimal","item9Flagged":false,"crisisShownAt":null,\
            "takenAt":"2026-01-01T00:00:00Z","createdAt":"2026-01-01T00:00:00Z"},\
            "actionThreshold":10,"crisis":null}}
            """
            return try Fixture(
                opKind: .createMentalHealthAssessment,
                payload: enc.encode(body),
                createPath: "/api/mental-health/assessments",
                successBody: Data(resp.utf8)
            )
        }
    }

    // MARK: - The contract

    @Test(
        "A retriable-then-succeed replay lands ONE row under a STABLE idempotency key",
        arguments: CreateKind.allCases
    )
    func retriableThenSucceedIsIdempotent(_ kind: CreateKind) async throws {
        let outbox = try OutboxQueue(inMemory: true)
        let api = makeAPI()
        let fx = try fixture(for: kind)

        // The persisted key: minted ONCE at enqueue, must ride every replay
        // verbatim. If any code path re-minted it, the recorded headers would
        // diverge and the server would insert a duplicate.
        let persistedKey = "contract-\(kind.rawValue)-key"
        try await outbox.enqueue(.init(
            kind: fx.opKind,
            payload: fx.payload,
            idempotencyKey: persistedKey
        ))

        let recorder = HeaderRecorder()
        // A per-pass switch: fail the first drain retriably (503), succeed the
        // second (200). Both attempts must carry the SAME persisted key.
        let outcome = OutcomeGate()
        MockURLProtocol.handler = { [path = fx.createPath, ok = fx.successBody] req in
            guard req.httpMethod == "POST", req.url?.path == path else {
                // Any off-route request would mean the wrong kind drained.
                return (HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, nil)
            }
            recorder.record(req.value(forHTTPHeaderField: "Idempotency-Key"))
            if outcome.isFailing {
                // 503 → retriable → shouldPersistToOutbox → row kept. EVERY POST
                // this pass fails, incl. the APIClient's internal 5xx retries.
                return (HTTPURLResponse(url: req.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!, nil)
            }
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, ok)
        }

        let replay = makeReplay(api: api, outbox: outbox)

        // Pass 1 — retriable failure (the whole pass fails). Row survives.
        outcome.setFailing(true)
        await replay.runOnce()
        #expect(await outbox.snapshot.count == 1, "\(kind): retriable failure must KEEP the row")
        let afterFail = await outbox.snapshot.first
        #expect(afterFail?.idempotencyKey == persistedKey, "\(kind): persisted key must be unchanged after a failure")
        #expect(afterFail?.attempts == 1, "\(kind): a retriable failure increments attempts")

        // Pass 2 — success. Row drains; the SAME key is re-sent (never re-minted).
        outcome.setFailing(false)
        await replay.runOnce()
        #expect(await outbox.snapshot.isEmpty, "\(kind): a 2xx replay drains the row (one op)")

        // The lock: exactly two attempts observed (one fail + one success), and
        // EVERY attempt carried the identical persisted key → the server dedups
        // to a single row. A re-minted key would show ≥2 distinct keys here —
        // the exact double-submit shape this contract forbids.
        // The CONTRACT is key-stability + drains-to-one-op, NOT an exact POST
        // count (the APIClient retries a 5xx internally, so pass 1 alone can emit
        // several POSTs). At least one failed + one succeeding POST, and EVERY
        // POST carried the identical persisted key → the server dedups to one row.
        // A re-minted key would show ≥2 DISTINCT keys here — the double-submit
        // shape this contract forbids.
        let keys = recorder.snapshot
        #expect(keys.count >= 2, "\(kind): expected at least fail + success POSTs, got \(keys.count)")
        #expect(keys.allSatisfy { $0 == persistedKey }, "\(kind): idempotency key must be byte-stable across retries")
        #expect(Set(keys).count == 1, "\(kind): exactly one distinct idempotency key across all attempts")
        #expect(Set(keys).count == 1, "\(kind): a fresh key across retries = duplicate row (the forbidden bug)")
    }
}

// MARK: - Test doubles (file-private, thread-safe)

/// Records every `Idempotency-Key` header seen, in order.
private final class HeaderRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String] = []

    func record(_ key: String?) {
        guard let key else { return }
        lock.lock()
        defer { lock.unlock() }
        keys.append(key)
    }

    var snapshot: [String] {
        lock.lock()
        defer { lock.unlock() }
        return keys
    }
}

/// Pass-scoped failure gate. Fails EVERY POST while `failing`, succeeds every
/// POST otherwise — the test flips it between the two replay passes. This is a
/// per-PASS boundary, not a per-CALL counter: the real `APIClient` retries a 5xx
/// internally, so a call-counting gate would let the internal retry recover
/// within pass 1 and drain the row early. Failing the whole first pass keeps the
/// retriable-failure semantics intact regardless of how many POSTs the client
/// attempts.
private final class OutcomeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var failing = true

    func setFailing(_ value: Bool) {
        lock.lock()
        defer { lock.unlock() }
        failing = value
    }

    var isFailing: Bool {
        lock.lock()
        defer { lock.unlock() }
        return failing
    }
}

// swiftlint:enable force_unwrapping
