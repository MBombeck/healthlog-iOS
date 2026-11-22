import Foundation
@testable import HealthLog
import Synchronization
import Testing

/// The server answers a repeated key from memory only when the body is the
/// one it stored under that key: it compares a hash of the body with its keys
/// sorted. The first request encodes the body the screen built, the replay
/// encodes what it read back from disk. These tests send a write into a dead
/// line, let the replay deliver it, and hold the two bodies against each
/// other in that sorted form.
@Suite("Write-ahead: the replay sends the body the first request carried", .serialized, .isolatedSkipRegister, .mockURLSession)
struct WriteAheadBodyParityTests {
    /// Not on a whole second: a date that lost its fraction on the way to disk
    /// and back would show here.
    private static let takenAt = Date(timeIntervalSince1970: 1_781_330_700.123)
    private static let plannedFor = Date(timeIntervalSince1970: 1_781_330_400.456)

    /// The body as the server hashes it: keys sorted at every depth, arrays in
    /// the order they came.
    private static func canonical(_ body: String) throws -> String {
        let object = try JSONSerialization.jsonObject(with: Data(body.utf8))
        let sorted = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(bytes: sorted, encoding: .utf8) ?? ""
    }

    /// Sends one write while no request gets through, then lets the replay
    /// deliver it. Returns what went out before and after, in canonical form.
    private func sentTwice(
        answer: Data,
        _ write: (APIClient, OutboxQueue) async throws -> Void
    ) async throws -> (first: [String], again: [String]) {
        let outbox = try OutboxQueue(inMemory: true, currentOwnerProvider: { WAFixture.owner })
        let lineIsUp = Mutex(false)
        let first = WABodyLog()
        let again = WABodyLog()
        MockURLProtocol.install { req in
            guard lineIsUp.withLock({ $0 }) else {
                first.add(req)
                throw URLError(.timedOut)
            }
            again.add(req)
            return WAFixture.reply(req, 201, answer)
        }

        var failed = false
        do {
            try await write(WAFixture.api(), outbox)
        } catch {
            failed = true
        }
        #expect(failed, "the first request was meant to fail")
        #expect(await outbox.snapshot.count == 1, "the write waits in the queue")

        lineIsUp.withLock { $0 = true }
        await WAFixture.replay(outbox: outbox).runOnce()
        #expect(await outbox.snapshot.isEmpty, "the replay delivered it")

        return try (first.all.map(Self.canonical), again.all.map(Self.canonical))
    }

    @Test("a new record with every field set goes again with the same body")
    func newRecord() async throws {
        let body = AllergyCreate(
            substance: "Penicillin",
            category: .medication,
            type: .allergy,
            severity: .severe,
            status: .active,
            onsetAt: "2019-04-02",
            reaction: "Hives, both arms",
            note: "Seen by Dr. Ortega"
        )
        let sent = try await sentTwice(answer: WAFixture.allergyCreated) { api, outbox in
            _ = try await AllergiesRepository(api: api, outbox: outbox).create(body)
        }

        let first = try #require(sent.first.first)
        #expect(first.contains("Hives, both arms"), "the body under test carries the fields the screen set")
        #expect(Set(sent.first) == [first], "every try of the first request carried one body")
        #expect(sent.again == [first])
    }

    @Test("a new record with only its name set goes again with the same body, no field added on the way")
    func sparseNewRecord() async throws {
        let sent = try await sentTwice(answer: WAFixture.allergyCreated) { api, outbox in
            _ = try await AllergiesRepository(api: api, outbox: outbox).create(AllergyCreate(substance: "Latex"))
        }

        let first = try #require(sent.first.first)
        #expect(sent.again == [first])
    }

    @Test("a planned dose goes again with the same body, the time it was taken included")
    func plannedDose() async throws {
        let sent = try await sentTwice(answer: WAFixture.intakeLogged) { api, outbox in
            _ = try await MedicationsRepository(api: api, outbox: outbox)
                .record(intake: "intake-1", status: .taken, takenAt: Self.takenAt, injectionSite: .thighLeft)
        }

        let first = try #require(sent.first.first)
        #expect(first.contains("THIGH_LEFT"))
        #expect(Set(sent.first) == [first])
        #expect(sent.again == [first])
    }

    @Test("a free dose goes again with the same body: both times, the dose, the site and the key the server stores")
    func freeDose() async throws {
        let sent = try await sentTwice(answer: WAFixture.intakeLogged) { api, outbox in
            _ = try await MedicationsRepository(api: api, outbox: outbox).logIntake(
                medicationId: "med-1",
                scheduledFor: Self.plannedFor,
                takenAt: Self.takenAt,
                skipped: false,
                doseTaken: "0.5 mg",
                injectionSite: .abdomenLeftUpper
            )
        }

        let first = try #require(sent.first.first)
        #expect(first.contains("0.5 mg"))
        #expect(first.contains("idempotencyKey"))
        #expect(Set(sent.first) == [first])
        #expect(sent.again == [first])
    }
}
