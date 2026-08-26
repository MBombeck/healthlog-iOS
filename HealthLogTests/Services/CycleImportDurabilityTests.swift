import Foundation
#if canImport(HealthKit)
    import HealthKit
#endif
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

#if canImport(HealthKit)

    /// **Phase 07 / plan 07-06 — what a cycle bulk response is allowed to prove.**
    ///
    /// The shipped importer read a 2xx as acceptance and saved the type's anchor,
    /// so an index the response skipped — or never mentioned at all — consumed the
    /// window it appeared in. Two rules replace that, and both are pinned here:
    /// acceptance is decided **per submitted index**, and anything short of
    /// terminal evidence must exist as a durable, owner-bound outbox row before
    /// that type's cursor may move.
    ///
    /// The query half of the sweep needs an authorized `HKHealthStore`, which a
    /// unit test does not have; the classification and the durable write are pure
    /// and are driven directly.
    @Suite("Cycle import durability — per-index acceptance and a durable hold", .serialized)
    struct CycleImportDurabilityTests {
        private static let owner = "account-a"

        private static func response(_ rows: [(index: Int, status: String)]) throws -> CycleBulkResponse {
            let entries = rows.map { #"{"index":\#($0.index),"status":"\#($0.status)"}"# }.joined(separator: ",")
            let json = #"{"entries":[\#(entries)]}"#
            return try JSONDecoder().decode(CycleBulkResponse.self, from: Data(json.utf8))
        }

        private static func write(_ date: String) -> CycleDayLogWrite {
            CycleDayLogWrite(
                date: date,
                flow: .medium,
                loggedAt: "\(date)T08:00:00Z",
                source: "APPLE_HEALTH",
                externalId: "cycle-hk:\(date)"
            )
        }

        private static func page(_ classifications: [HealthSyncAcceptanceClass?], retryPersisted: Bool)
            -> HealthSyncPageOutcome
        {
            HealthSyncPageOutcome(
                postedCount: classifications.count,
                entries: classifications.enumerated().map { index, classification in
                    HealthSyncEntryOutcome(
                        index: index,
                        stableIdentity: "cycle-hk:2026-05-0\(index)",
                        classification: classification
                    )
                },
                transportThrew: false,
                durableRetryPersisted: retryPersisted,
                durableRetryFailed: !retryPersisted,
                leaseIsCurrent: true,
                wasCancelled: false
            )
        }

        // MARK: - Per-index acceptance

        @Test("the three success shapes are terminal, a skip is not")
        func statusVocabularyIsExact() throws {
            let verdict = try CycleHealthKitImporter.acceptance(
                of: Self.response([
                    (0, "inserted"),
                    (1, "updated"),
                    (2, "duplicate"),
                    (3, "skipped")
                ]),
                sliceCount: 4
            )
            #expect(verdict == [.terminalAccepted, .terminalAccepted, .terminalAccepted, .nonterminal])
        }

        @Test("an index the response never mentions has no evidence at all")
        func missingIndexIsUnclassified() throws {
            let verdict = try CycleHealthKitImporter.acceptance(
                of: Self.response([(0, "inserted")]),
                sliceCount: 3
            )
            #expect(verdict == [.terminalAccepted, nil, nil])
            // And an unclassified index is what the shared rule refuses to let a
            // cursor step over.
            #expect(
                HealthSyncCursorPolicy.installed.decide(Self.page(verdict, retryPersisted: false))
                    != .commit
            )
        }

        @Test("a repeated index is an ambiguous answer, not a second one")
        func repeatedIndexIsUnclassified() throws {
            let verdict = try CycleHealthKitImporter.acceptance(
                of: Self.response([(0, "inserted"), (0, "skipped")]),
                sliceCount: 1
            )
            #expect(verdict == [nil])
        }

        @Test("an out-of-range index cannot classify a row that was never posted")
        func outOfRangeIndexIsIgnored() throws {
            let verdict = try CycleHealthKitImporter.acceptance(
                of: Self.response([(0, "inserted"), (7, "inserted")]),
                sliceCount: 1
            )
            #expect(verdict == [.terminalAccepted])
        }

        // MARK: - What the page means for the cursor

        @Test("a held day-log may only close its window once it is durably queued")
        func heldRowNeedsADurableHome() {
            let held = Self.page([.terminalAccepted, .nonterminal], retryPersisted: false)
            #expect(HealthSyncCursorPolicy.installed.decide(held) == .hold(reason: .retryPersistenceFailed))

            let queued = Self.page([.terminalAccepted, .nonterminal], retryPersisted: true)
            #expect(HealthSyncCursorPolicy.installed.decide(queued) == .commit)
        }

        @Test("a fully accepted page moves the cursor")
        func acceptedPageCommits() {
            let accepted = HealthSyncPageOutcome(
                postedCount: 2,
                entries: [
                    HealthSyncEntryOutcome(index: 0, stableIdentity: "cycle-hk:2026-05-01", classification: .terminalAccepted),
                    HealthSyncEntryOutcome(index: 1, stableIdentity: "cycle-hk:2026-05-02", classification: .terminalAccepted)
                ],
                transportThrew: false,
                durableRetryPersisted: false,
                durableRetryFailed: false,
                leaseIsCurrent: true,
                wasCancelled: false
            )
            #expect(HealthSyncCursorPolicy.installed.decide(accepted) == .commit)
        }

        // MARK: - The durable write

        @Test("a held day-log lands as an owner-stamped outbox row under the derived key")
        func durableEnqueueIsOwnerBoundAndDerived() async throws {
            let outbox = try OutboxQueue(inMemory: true, currentOwnerProvider: { Self.owner })
            let repo = CycleRepository(api: makeAPI(), outbox: outbox)
            let envelope = try #require(
                HealthSyncRetryEnvelope(
                    ownerID: Self.owner,
                    source: .cycle,
                    stableIdentity: "cycle-hk:2026-05-01"
                )
            )

            try await repo.enqueueDurableDayLog(
                Self.write("2026-05-01"),
                idempotencyKey: envelope.idempotencyKey,
                requiringCurrentOwner: Self.owner
            )

            let rows = await outbox.snapshot
            #expect(rows.count == 1)
            #expect(rows.first?.kind == .logCycleDayLog)
            #expect(rows.first?.ownerUserID == Self.owner)
            #expect(rows.first?.idempotencyKey == envelope.idempotencyKey)
        }

        @Test("a relaunch rebuilds the same operation instead of writing a second one")
        func derivedKeyIsRestartStable() throws {
            let before = try #require(
                HealthSyncRetryEnvelope(ownerID: Self.owner, source: .cycle, stableIdentity: "cycle-hk:2026-05-01")
            )
            let afterRelaunch = try #require(
                HealthSyncRetryEnvelope(ownerID: Self.owner, source: .cycle, stableIdentity: "cycle-hk:2026-05-01")
            )
            let otherDay = try #require(
                HealthSyncRetryEnvelope(ownerID: Self.owner, source: .cycle, stableIdentity: "cycle-hk:2026-05-02")
            )
            let otherOwner = try #require(
                HealthSyncRetryEnvelope(ownerID: "account-b", source: .cycle, stableIdentity: "cycle-hk:2026-05-01")
            )

            #expect(before.idempotencyKey == afterRelaunch.idempotencyKey)
            #expect(before.idempotencyKey != otherDay.idempotencyKey)
            #expect(before.idempotencyKey != otherOwner.idempotencyKey)
        }

        @Test("a lost durable write throws — it is not the same fact as a queued one")
        func lostDurableWriteThrows() async throws {
            let outbox = try OutboxQueue(inMemory: true, currentOwnerProvider: { Self.owner })
            let repo = CycleRepository(api: makeAPI(), outbox: outbox)

            // The account this write was captured for no longer owns the session.
            await #expect(throws: (any Error).self) {
                try await repo.enqueueDurableDayLog(
                    Self.write("2026-05-01"),
                    idempotencyKey: "irrelevant",
                    requiringCurrentOwner: ""
                )
            }
            let rows = await outbox.snapshot
            #expect(rows.isEmpty)
        }

        private func makeAPI() -> APIClient {
            let env = AppEnvironment(
                baseURL: URL(string: "https://test.healthlog.local")!,
                bundleID: "dev.healthlog.app",
                appVersion: "0.14.1",
                buildNumber: "1"
            )
            return APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
        }
    }

#endif

// swiftlint:enable force_unwrapping
