import Foundation
@testable import HealthLog
import Synchronization
import Testing

// swiftlint:disable force_unwrapping

/// #12 — a queued take the server answers "already taken" is delivered.
///
/// The take waited offline while the pill box recorded the same slot. The
/// server records nothing and says when the first dose was taken. Up to 1.6 the
/// replay dead-lettered the row as `unroutable` (the error is not an
/// `HLError`) and offered "Erneut senden", which met the same answer again.
@Suite("Outbox replay — alreadyTaken is a delivery (#12)", .serialized, .mockURLSession)
struct OutboxAlreadyTakenReplayTests {
    static let owner = "account-m"
    static let baseURL = URL(string: "https://test.healthlog.local")!

    @Test("the row goes, nothing is dead-lettered or discarded, and the first take is announced")
    func alreadyTakenIsDelivered() async throws {
        MockURLProtocol.install { req in
            let body = #"""
            {"data":{"id":"row-1","medicationId":"med-1","scheduledFor":"2026-11-21T07:00:00.000Z",
            "takenAt":"2026-11-21T07:12:00.000Z","skipped":false,"takenVia":"TELEGRAM","syncVersion":3,
            "alreadyTaken":true}}
            """#
            return (
                HTTPURLResponse(
                    url: req.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(body.utf8)
            )
        }
        let keychain = InMemoryKeychain()
        try? keychain.setString("bearer-m", forKey: KeychainKey.authToken)
        try? keychain.setString(Self.owner, forKey: KeychainKey.userID)
        let api = APIClient(
            environment: AppEnvironment(
                baseURL: Self.baseURL,
                bundleID: "dev.healthlog.app",
                appVersion: "1.7.0",
                buildNumber: "1"
            ),
            keychain: keychain,
            sessionConfiguration: .mock()
        )
        let outbox = try OutboxQueue(inMemory: true, currentOwnerProvider: { Self.owner })
        try await outbox.enqueue(.init(
            kind: .takeMedication,
            payload: JSONEncoder.hlDefault.encode(
                MedicationsRepository.IntakeUpdate(intakeId: "row-1", status: "taken", takenAt: Date(timeIntervalSince1970: 1_795_000_000))
            ),
            idempotencyKey: "take-row-1",
            ownerUserID: Self.owner
        ))
        let discards = Mutex<[OutboxDiscardNotice]>([])
        let announced = Mutex<[MedicationAlreadyTaken]>([])
        let replay = OutboxReplayService(
            outbox: outbox,
            measurementsRepo: MeasurementsRepository(api: api, outbox: outbox),
            moodRepo: MoodRepository(api: api, outbox: outbox),
            medicationsRepo: MedicationsRepository(api: api, outbox: outbox),
            currentUserProvider: { Self.owner },
            attemptBackoff: 0,
            onDiscarded: { notices in discards.withLock { $0.append(contentsOf: notices) } }
        )
        replay.setAlreadyTakenNotifier { already in announced.withLock { $0.append(already) } }

        await replay.runOnce()

        #expect(await outbox.snapshot.isEmpty, "the dose is on the server: nothing left to send")
        #expect(await outbox.deadLetterCount == 0)
        #expect(discards.withLock { $0 }.isEmpty, "not a failure")
        let first = try #require(announced.withLock { $0 }.first)
        #expect(first.source == "TELEGRAM")
        #expect(first.takenAt == ISO8601DateFormatter().date(from: "2026-11-21T07:12:00Z"))
    }
}

// swiftlint:enable force_unwrapping
