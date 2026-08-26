import Foundation
@testable import HealthLog
import Testing

/// Phase 07 Wave 0 — the durable cursor matrix.
///
/// The upstream order is `read anchor → query → app callback → save anchor`
/// (SpeziHealthKit 1.4.2, revision `a86db5c`). A rewind performed inside the
/// callback cannot recover anything, because the query that produced the page
/// already ran from the old anchor and the library overwrites the rewind on
/// return. This suite models that order exactly, then requires that a cursor
/// only advances after exact terminal acceptance or a durable, owner-bound
/// retry — never across cancellation, a lost lease, or a lost retry write.
@Suite("HealthKit durable cursor")
struct HealthKitDurableCursorTests {
    // MARK: - Upstream ordering model

    /// One observable step of the upstream collector.
    enum CollectorStep: Equatable {
        case readAnchor(String?)
        case query(fromAnchor: String?)
        case handler(pageAnchor: String?)
        case saveAnchor(String?)
    }

    /// Faithful model of `HealthKitSampleCollector.anchoredSingleObjectQuery` /
    /// `anchoredContinuousObjectQuery` in SpeziHealthKit 1.4.2: the anchor is
    /// read once, the query runs from it, the app handler is awaited, and the
    /// query's new anchor is then persisted unconditionally.
    final class UpstreamOrderedCollector {
        private(set) var storedAnchor: String?
        private(set) var steps: [CollectorStep] = []

        init(storedAnchor: String?) {
            self.storedAnchor = storedAnchor
        }

        func collect(newAnchor: String, handler: (UpstreamOrderedCollector) -> Void) {
            let resumeAnchor = storedAnchor
            steps.append(.readAnchor(resumeAnchor))
            steps.append(.query(fromAnchor: resumeAnchor))
            steps.append(.handler(pageAnchor: newAnchor))
            handler(self)
            storedAnchor = newAnchor
            steps.append(.saveAnchor(newAnchor))
        }

        /// What `HealthLogStandard` does today when it holds an upload.
        func rewind(to anchor: String?) {
            storedAnchor = anchor
        }
    }

    @Test("upstream reads the anchor before the callback and saves it afterwards")
    func upstreamOrderIsReadQueryCallbackSave() {
        let collector = UpstreamOrderedCollector(storedAnchor: "anchor-1")
        collector.collect(newAnchor: "anchor-2") { _ in }

        #expect(collector.steps == [
            .readAnchor("anchor-1"),
            .query(fromAnchor: "anchor-1"),
            .handler(pageAnchor: "anchor-2"),
            .saveAnchor("anchor-2")
        ])
    }

    @Test("a callback rewind cannot recover the page the query already consumed")
    func callbackRewindIsOverwritten() {
        let collector = UpstreamOrderedCollector(storedAnchor: "anchor-1")
        collector.collect(newAnchor: "anchor-2") { collector in
            collector.rewind(to: "anchor-1")
        }

        #expect(collector.storedAnchor == "anchor-2")
        #expect(collector.steps.last == .saveAnchor("anchor-2"))
    }

    // MARK: - Cursor identity and migration

    @Test("cursor keys are owner scoped and fail closed")
    func cursorKeysAreOwnerScoped() throws {
        #expect(HealthSyncCursorKey(ownerID: "", source: .speziSamples, typeIdentifier: "type") == nil)
        #expect(HealthSyncCursorKey(ownerID: "  ", source: .speziSamples, typeIdentifier: "type") == nil)
        #expect(HealthSyncCursorKey(ownerID: "owner", source: .speziSamples, typeIdentifier: "") == nil)

        let ownerA = try #require(
            HealthSyncCursorKey(ownerID: "account-a", source: .speziSamples, typeIdentifier: "HKStepCount")
        )
        let ownerB = try #require(
            HealthSyncCursorKey(ownerID: "account-b", source: .speziSamples, typeIdentifier: "HKStepCount")
        )
        let otherSource = try #require(
            HealthSyncCursorKey(ownerID: "account-a", source: .heartEvent, typeIdentifier: "HKStepCount")
        )

        #expect(ownerA.storageKey != ownerB.storageKey)
        #expect(ownerA.storageKey != otherSource.storageKey)
        #expect(!ownerA.storageKey.contains("account-a"))
        #expect(ownerA.storageKey.hasPrefix("hl.sync.cursor.v2."))
    }

    @Test("migration state fails closed until a verified read back")
    func migrationStateFailsClosed() {
        #expect(!HealthSyncCursorMigrationState.notStarted.permitsCollection)
        #expect(!HealthSyncCursorMigrationState.failed(reason: "write not verified").permitsCollection)
        #expect(HealthSyncCursorMigrationState.replayingLegacy(quarantineReference: "q-1").permitsCollection)
        #expect(HealthSyncCursorMigrationState.verified.permitsCollection)

        #expect(!HealthSyncCursorMigrationState.notStarted.isComplete)
        #expect(!HealthSyncCursorMigrationState.replayingLegacy(quarantineReference: "q-1").isComplete)
        #expect(!HealthSyncCursorMigrationState.failed(reason: "skipped").isComplete)
        #expect(HealthSyncCursorMigrationState.verified.isComplete)
    }

    // MARK: - Fault matrix

    struct MatrixRow {
        let name: String
        let outcome: HealthSyncPageOutcome
        let requiredDecision: HealthSyncCommitDecision
    }

    static func accepted(_ count: Int) -> [HealthSyncEntryOutcome] {
        (0 ..< count).map {
            HealthSyncEntryOutcome(index: $0, stableIdentity: "sample-\($0)", classification: .terminalAccepted)
        }
    }

    static var matrix: [MatrixRow] {
        let complete = accepted(2)
        let missing = accepted(1)
        let repeated = [
            HealthSyncEntryOutcome(index: 0, stableIdentity: "sample-0", classification: .terminalAccepted),
            HealthSyncEntryOutcome(index: 0, stableIdentity: "sample-1", classification: .terminalAccepted)
        ]
        let unclassified = [
            HealthSyncEntryOutcome(index: 0, stableIdentity: "sample-0", classification: .terminalAccepted),
            HealthSyncEntryOutcome(index: 1, stableIdentity: "sample-1", classification: nil)
        ]
        let rejected = [
            HealthSyncEntryOutcome(index: 0, stableIdentity: "sample-0", classification: .terminalAccepted),
            HealthSyncEntryOutcome(index: 1, stableIdentity: "sample-1", classification: .nonterminal)
        ]

        func outcome(
            _ entries: [HealthSyncEntryOutcome],
            transportThrew: Bool = false,
            retryPersisted: Bool = false,
            retryFailed: Bool = false,
            leaseIsCurrent: Bool = true,
            cancelled: Bool = false
        ) -> HealthSyncPageOutcome {
            HealthSyncPageOutcome(
                postedCount: 2,
                entries: entries,
                transportThrew: transportThrew,
                durableRetryPersisted: retryPersisted,
                durableRetryFailed: retryFailed,
                leaseIsCurrent: leaseIsCurrent,
                wasCancelled: cancelled
            )
        }

        return [
            MatrixRow(name: "every posted index terminal", outcome: outcome(complete), requiredDecision: .commit),
            MatrixRow(
                name: "missing response index",
                outcome: outcome(missing, transportThrew: true),
                requiredDecision: .hold(reason: .incompleteIndexCoverage)
            ),
            MatrixRow(
                name: "repeated response index",
                outcome: outcome(repeated, transportThrew: true),
                requiredDecision: .hold(reason: .incompleteIndexCoverage)
            ),
            MatrixRow(
                name: "unclassified status word",
                outcome: outcome(unclassified, transportThrew: true),
                requiredDecision: .hold(reason: .nonterminalEntry)
            ),
            MatrixRow(
                name: "rejected row with durable retry",
                outcome: outcome(rejected, retryPersisted: true),
                requiredDecision: .commit
            ),
            MatrixRow(
                name: "rejected row without durable retry",
                outcome: outcome(rejected),
                requiredDecision: .hold(reason: .nonterminalEntry)
            ),
            MatrixRow(
                name: "durable retry write lost",
                outcome: outcome(rejected, retryFailed: true),
                requiredDecision: .hold(reason: .retryPersistenceFailed)
            ),
            MatrixRow(
                name: "cancelled mid page",
                outcome: outcome(complete, cancelled: true),
                requiredDecision: .hold(reason: .cancelled)
            ),
            MatrixRow(
                name: "lease lost mid page",
                outcome: outcome(complete, leaseIsCurrent: false),
                requiredDecision: .hold(reason: .leaseLost)
            )
        ]
    }

    @Test("the required rule holds every fault and commits only exact acceptance")
    func requiredPolicyMatchesTheMatrix() {
        for row in Self.matrix {
            #expect(
                HealthSyncCursorPolicy.required.decide(row.outcome) == row.requiredDecision,
                "required rule disagrees on: \(row.name)"
            )
        }
    }

    // MARK: - RED

    /// No fault the durable rule holds may advance the installed cursor, and the
    /// production Spezi paths must consult the shared commit and migration
    /// contracts instead of persisting the library anchor unconditionally.
    @Test("a nonterminal page holds the cursor")
    func nonterminalPageHoldsCursor() throws {
        var violations: [String] = []

        for row in Self.matrix {
            let installed = HealthSyncCursorPolicy.installed.decide(row.outcome)
            guard case .hold = row.requiredDecision else { continue }
            if installed == .commit {
                violations.append("installed rule advanced the cursor on: \(row.name)")
            }
        }

        let bindings = [
            ("HealthLog/Services/HealthKit/HealthLogStandard.swift", "HealthSyncCursorPolicy"),
            ("HealthLog/Services/HealthKit/SpeziAnchorMigrator.swift", "HealthSyncCursorMigrationState")
        ]
        for (path, symbol) in bindings {
            let contents = try Self.source(path)
            if !contents.contains(symbol) {
                violations.append("\(path) does not consult \(symbol)")
            }
        }

        #expect(violations.isEmpty, "EXPECTED_RED: nonterminal page advanced cursor")
    }

    // MARK: - Source access

    private static func source(_ relativePath: String, file: String = #filePath) throws -> String {
        let root = URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
