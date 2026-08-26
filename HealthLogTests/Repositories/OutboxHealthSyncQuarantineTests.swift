import Foundation
@testable import HealthLog
import SwiftData
import Testing

// swiftlint:disable force_unwrapping

/// Phase 07 Wave 0 — outbox quarantine for rows this build cannot own.
///
/// Two on-disk shapes are still adopted today. A row whose `ownerUserID` is
/// `nil` or blank replays as if the current user had written it, and a row
/// whose `kindRaw` this build does not recognise decodes into the
/// `syncHealthKitSample` sentinel and is dropped. Both are health writes whose
/// owner or meaning is unknown: they must be retained, never transmitted,
/// never deleted, and never re-stamped with the live owner.
@Suite("Outbox HealthKit sync quarantine", .serialized)
struct OutboxHealthSyncQuarantineTests {
    private static let measurementSuccessBody = Data(
        #"""
        {
          "data": {
            "id": "srv-q", "type": "WEIGHT", "value": 70.0, "unit": "kg",
            "measuredAt": "2026-08-14T10:00:00Z", "createdAt": "2026-08-14T10:00:00Z",
            "source": "MANUAL", "externalId": null, "note": null
          }
        }
        """#.utf8
    )

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func increment() {
            lock.lock()
            defer { lock.unlock() }
            value += 1
        }

        var current: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private func makeAPI() -> APIClient {
        let environment = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            cfAccessClientID: nil,
            cfAccessClientToken: nil,
            bundleID: "dev.healthlog.app",
            appVersion: "0.1.0",
            buildNumber: "1"
        )
        return APIClient(environment: environment, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
    }

    private func makeReplay(
        api: APIClient,
        outbox: OutboxQueue,
        currentUser: @escaping @Sendable () -> String?
    ) -> OutboxReplayService {
        OutboxReplayService(
            outbox: outbox,
            measurementsRepo: MeasurementsRepository(api: api, outbox: outbox),
            moodRepo: MoodRepository(api: api, outbox: outbox),
            medicationsRepo: MedicationsRepository(api: api, outbox: outbox),
            currentUserProvider: currentUser,
            maxAttempts: 8
        )
    }

    private func encodeMeasurement() throws -> Data {
        let measurement = Measurement(
            id: "local-quarantine",
            kind: .weight,
            recordedAt: Date(timeIntervalSince1970: 1_755_000_000),
            value: .scalar(70.0)
        )
        return try JSONEncoder.hlDefault.encode(measurement)
    }

    // MARK: - Established behaviour that must not regress

    @Test("a foreign-owned row is still never transmitted")
    func foreignOwnedRowIsNotTransmitted() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true, currentOwnerProvider: { "user-a" })
        try await outbox.enqueue(.init(
            kind: .createMeasurement,
            payload: encodeMeasurement(),
            idempotencyKey: "quarantine-foreign"
        ))

        let attempts = Counter()
        MockURLProtocol.handler = { request in
            attempts.increment()
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, nil)
        }
        let replay = makeReplay(api: api, outbox: outbox, currentUser: { "user-b" })
        await replay.runOnce()

        #expect(attempts.current == 0)
    }

    @Test("the outbox drain is a named sync capability")
    func outboxDrainIsNamed() {
        #expect(HealthSyncCapability.outboxDrain.source == .outbox)
        #expect(!HealthSyncCapability.outboxDrain.isSampleCollection)
        #expect(HealthSyncCompositionPlan.required(for: .manual).contains(.outboxDrain))
        #expect(HealthSyncCompositionPlan.required(for: .appRefresh).contains(.outboxDrain))
    }

    // MARK: - RED

    /// Neither an unowned row nor an unknown-kind row may be transmitted,
    /// deleted, or adopted by the signed-in account.
    @Test("unknown and nil owner rows remain quarantined")
    func unknownAndNilOwnerRowsRemainQuarantined() async throws {
        var violations: [String] = []

        for (label, kindRaw, owner) in [
            ("nil-owner", "createMeasurement", String?.none),
            ("blank-owner", "createMeasurement", String?.some("   ")),
            ("unknown-kind", "futureUnknownKind", String?.some("user-current"))
        ] {
            let api = makeAPI()
            let container = try OutboxStore.makeInMemory()
            let store = OutboxStore(modelContainer: container)
            try await store.enqueue(
                id: UUID(),
                kindRaw: kindRaw,
                payload: encodeMeasurement(),
                idempotencyKey: "quarantine-\(label)",
                createdAt: .now,
                ownerUserID: owner
            )
            let outbox = OutboxQueue(testContainer: container, currentOwnerProvider: { "user-current" })

            let attempts = Counter()
            MockURLProtocol.handler = { request in
                attempts.increment()
                return (
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Self.measurementSuccessBody
                )
            }
            let replay = makeReplay(api: api, outbox: outbox, currentUser: { "user-current" })
            await replay.runOnce()

            let remaining = await outbox.snapshot
            if attempts.current != 0 {
                violations.append("\(label) row reached the server")
            }
            if remaining.isEmpty {
                violations.append("\(label) row was deleted instead of quarantined")
            }
            if let row = remaining.first, row.ownerUserID == "user-current", owner != "user-current" {
                violations.append("\(label) row adopted the signed-in owner")
            }
        }

        #expect(violations.isEmpty, "EXPECTED_RED: unowned outbox row was transmitted deleted or adopted")
    }
}

// swiftlint:enable force_unwrapping
