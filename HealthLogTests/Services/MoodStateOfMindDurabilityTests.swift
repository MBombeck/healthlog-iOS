import Foundation
@testable import HealthLog
import Testing

#if canImport(HealthKit)

    /// **Phase 07 / plan 07-05 — how a State-of-Mind page reaches its anchor.**
    ///
    /// The Wave-0 RED (`MoodImportDurabilityTests/enqueueFailureHoldsAnchor`)
    /// states the rule. This suite states the mapping that feeds it: which
    /// repository outcome is progress, which one is a hole, and what the two
    /// produce when the shared commit rule is asked about the page they build.
    @Suite("State of Mind — outcome classification and the anchor it produces")
    struct MoodStateOfMindDurabilityTests {
        private static let entry = MoodEntry(
            id: "local-1",
            recordedAt: Date(timeIntervalSince1970: 1_783_000_000),
            score: 3
        )

        @Test("An accepted or queued write is progress; a lost enqueue is not")
        func classificationSeparatesQueuedFromLost() {
            #expect(
                MoodStateOfMindImporter.classification(of: .accepted(Self.entry)) == .terminalAccepted
            )
            #expect(
                MoodStateOfMindImporter.classification(
                    of: .queued(Self.entry, transport: .offline)
                ) == .terminalAccepted
            )
            #expect(
                MoodStateOfMindImporter.classification(of: .enqueueLost(.notPersisted("outbox lost"))) == .nonterminal
            )
        }

        /// Deliberate, and the reason is written down in the production doc
        /// comment: a refusal a retry cannot fix would otherwise turn one
        /// malformed sample into a permanently stalled importer. It is the same
        /// call the medication path makes for `unstable_external_id`.
        @Test("A refusal a retry cannot fix is terminal, not a permanent hold")
        func aNonRetriableRefusalIsTerminal() {
            #expect(
                MoodStateOfMindImporter.classification(
                    of: .rejected(.server(status: 422, code: nil, message: "Validation failed"))
                ) == .terminalAccepted
            )
        }

        @Test("A page whose durable write was lost holds the anchor")
        func aLostEnqueueHoldsTheAnchor() {
            let page = Self.page(
                classification: MoodStateOfMindImporter.classification(of: .enqueueLost(.notPersisted("outbox lost"))),
                retryPersisted: false,
                retryFailed: true
            )
            #expect(
                HealthSyncCursorPolicy.installed.decide(page) == .hold(reason: .retryPersistenceFailed)
            )
        }

        @Test("A page whose durable write landed commits the anchor")
        func aQueuedWriteCommitsTheAnchor() {
            let page = Self.page(
                classification: MoodStateOfMindImporter.classification(
                    of: .queued(Self.entry, transport: .offline)
                ),
                retryPersisted: true,
                retryFailed: false
            )
            #expect(HealthSyncCursorPolicy.installed.decide(page) == .commit)
        }

        @Test("A cancelled page commits nothing, which is what makes the teardown drain safe")
        func aCancelledPageHolds() {
            var page = Self.page(classification: .terminalAccepted, retryPersisted: false, retryFailed: false)
            page = HealthSyncPageOutcome(
                postedCount: page.postedCount,
                entries: page.entries,
                transportThrew: false,
                durableRetryPersisted: false,
                durableRetryFailed: false,
                leaseIsCurrent: true,
                wasCancelled: true
            )
            #expect(HealthSyncCursorPolicy.installed.decide(page) == .hold(reason: .cancelled))
        }

        @Test("A page finished under a replaced account commits nothing")
        func aLateAccountPageHolds() {
            let page = HealthSyncPageOutcome(
                postedCount: 1,
                entries: [
                    HealthSyncEntryOutcome(index: 0, stableIdentity: "hk-mood-1", classification: .terminalAccepted)
                ],
                transportThrew: false,
                durableRetryPersisted: false,
                durableRetryFailed: false,
                leaseIsCurrent: false,
                wasCancelled: false
            )
            #expect(HealthSyncCursorPolicy.installed.decide(page) == .hold(reason: .leaseLost))
        }

        @Test("The mood cursor partition is owner-bound and hashes its owner")
        func theCursorPartitionIsOwnerBound() throws {
            let keyA = try #require(
                HealthSyncCursorKey(
                    ownerID: "account-a",
                    source: .mood,
                    typeIdentifier: MoodStateOfMindImporter.cursorTypeIdentifier
                )
            )
            let keyB = try #require(
                HealthSyncCursorKey(
                    ownerID: "account-b",
                    source: .mood,
                    typeIdentifier: MoodStateOfMindImporter.cursorTypeIdentifier
                )
            )
            #expect(keyA.storageKey != keyB.storageKey)
            #expect(!keyA.storageKey.contains("account-a"))
        }

        private static func page(
            classification: HealthSyncAcceptanceClass,
            retryPersisted: Bool,
            retryFailed: Bool
        ) -> HealthSyncPageOutcome {
            HealthSyncPageOutcome(
                postedCount: 1,
                entries: [
                    HealthSyncEntryOutcome(index: 0, stableIdentity: "hk-mood-1", classification: classification)
                ],
                transportThrew: false,
                durableRetryPersisted: retryPersisted,
                durableRetryFailed: retryFailed,
                leaseIsCurrent: true,
                wasCancelled: false
            )
        }
    }

#endif
