import Foundation
#if canImport(HealthKit)
    import HealthKit
#endif
@testable import HealthLog
import os
import Testing

// swiftlint:disable force_unwrapping

#if canImport(HealthKit)

    /// E1 — `cycle.bulk.invalid` / `cycle.bulk.too_large` (422, final "for the
    /// batch as sent", `src/app/api/cycle/day-logs/bulk/route.ts`, codes present
    /// since v1.39.0, documented as final in v1.39.1) must never be repeated
    /// forever and never deleted silently.
    ///
    /// Pinned end to end: the HealthKit cycle import meets the refusal, queues
    /// one outbox row per day (the anchor may move — each day has a durable
    /// copy), and the replay sends each day on its own. The valid day lands;
    /// the day the server names is set aside in the dead-letter lane (retained,
    /// counted, reported as refused) and never sent again. C4 already routes a
    /// named 4xx there; this suite states it for the cycle route.
    @Suite("cycle.bulk.* — a named refusal is set aside, the valid days land", .serialized, .mockURLSession)
    struct CycleBulkRefusalTests {
        static let owner = "account-e1c"

        /// `returnAllZodIssues(parsed.error, 422, { errorCode: "cycle.bulk.invalid" })`.
        static let bulkInvalid =
            #"{"data":null,"error":"Validation failed","details":{"issues":[{"path":"entries.1.flow","code":"invalid_value","message":"Invalid option"}]},"meta":{"errorCode":"cycle.bulk.invalid"}}"#
        static let singleInvalid =
            #"{"data":null,"error":"Validation failed","details":{"issues":[{"path":"entries.0.flow","code":"invalid_value","message":"Invalid option"}]},"meta":{"errorCode":"cycle.bulk.invalid"}}"#
        static let singleStored = #"{"data":{"entries":[{"index":0,"status":"inserted"}]},"error":null}"#

        static func write(_ date: String) -> CycleDayLogWrite {
            CycleDayLogWrite(
                date: date,
                flow: .medium,
                loggedAt: "\(date)T08:00:00Z",
                source: "APPLE_HEALTH",
                externalId: "cycle-hk:\(date)"
            )
        }

        static func makeAPI() throws -> APIClient {
            let keychain = InMemoryKeychain()
            try keychain.setString("bearer-e1c", forKey: KeychainKey.authToken)
            try keychain.setString(owner, forKey: KeychainKey.userID)
            let env = AppEnvironment(
                baseURL: URL(string: "https://test.healthlog.local"),
                bundleID: "dev.healthlog.app",
                appVersion: "1.1.0",
                buildNumber: "1"
            )
            return APIClient(environment: env, keychain: keychain, sessionConfiguration: .mock())
        }

        @Test("live import queues each day; the replay lands the valid one and sets the named one aside")
        func namedRefusalIsSetAside() async throws {
            let registry = AuthenticatedSessionLeaseRegistry()
            registry.activate(ownerID: Self.owner)
            let lease = try HealthSyncAuthenticatedLease.admit(
                from: registry,
                ownerID: Self.owner,
                source: .cycle,
                bearerProvider: { "bearer-e1c" }
            )
            let answers = [(422, Self.bulkInvalid), (200, Self.singleStored), (422, Self.singleInvalid)]
            let served = OSAllocatedUnfairLock(initialState: 0)
            MockURLProtocol.install { req in
                let index = served.withLock { count in
                    defer { count += 1 }
                    return min(count, answers.count - 1)
                }
                let response = HTTPURLResponse(
                    url: req.url!,
                    statusCode: answers[index].0,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (response, Data(answers[index].1.utf8))
            }
            let api = try Self.makeAPI()
            let outbox = try OutboxQueue(inMemory: true, currentOwnerProvider: { Self.owner })
            let cycleRepo = CycleRepository(api: api, outbox: outbox)
            let importer = try CycleHealthKitImporter(
                store: HKHealthStore(),
                repo: cycleRepo,
                userID: Self.owner,
                defaults: #require(UserDefaults(suiteName: "e1-cycle-\(UUID().uuidString)"))
            )

            let page = await importer.drain([Self.write("2026-09-10"), Self.write("2026-09-11")], requiring: lease)
            #expect(page.durableRetryPersisted)
            #expect(HealthSyncCursorPolicy.installed.decide(page) == .commit)
            #expect(await outbox.snapshot.count == 2)

            let discards = C4Discards()
            let replay = OutboxReplayService(
                outbox: outbox,
                measurementsRepo: MeasurementsRepository(api: api, outbox: outbox),
                moodRepo: MoodRepository(api: api, outbox: outbox),
                medicationsRepo: MedicationsRepository(api: api, outbox: outbox),
                cycleRepo: cycleRepo,
                currentUserProvider: { Self.owner },
                attemptBackoff: 0,
                onDiscarded: { notices in discards.add(notices) }
            )
            await replay.runOnce()
            await replay.runOnce()

            #expect(await outbox.snapshot.isEmpty, "nothing is left to repeat")
            #expect(await outbox.deadLetterCount == 1, "the refused day is retained, not deleted")
            #expect(discards.all == [.init(kind: "logCycleDayLog", reason: .serverRejected)])
            #expect(served.withLock { $0 } == 3, "one live bulk, one send per day, nothing repeated")
        }
    }

#endif

// swiftlint:enable force_unwrapping
