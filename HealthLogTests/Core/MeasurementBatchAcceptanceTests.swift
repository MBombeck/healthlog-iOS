import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// Phase 07 / Plan 07-04 — the exact, reason-aware acceptance gate.
///
/// Every assertion here is about one question: does this posted index carry
/// evidence strong enough to move a cursor that can never be rewound? The gate
/// is fail-closed, so the interesting cases are all the shapes that must *not*
/// count as evidence.
@Suite("MeasurementBatchAcceptance — exact indexed, reason-aware acceptance")
struct MeasurementBatchAcceptanceTests {
    // MARK: - Helpers

    private static func statIdentity(_ day: String = "2026-08-14") -> String {
        "stats:HKQuantityTypeIdentifierStepCount:\(day)"
    }

    private static func response(
        _ entries: [HealthKitBatchResponseDTO.EntryResult],
        skipped: [HealthKitBatchResponseDTO.SkippedEntry] = []
    ) -> HealthKitBatchResponseDTO {
        HealthKitBatchResponseDTO(
            processed: entries.count,
            inserted: 0,
            duplicates: 0,
            skipped: skipped,
            entries: entries
        )
    }

    private static func accepts(
        postedCount: Int,
        externalIds: [String]? = nil,
        _ response: HealthKitBatchResponseDTO
    ) -> Bool {
        MeasurementBatchAcceptance.classify(
            postedCount: postedCount,
            postedExternalIds: externalIds,
            response: response
        ).isCompletelyAccepted
    }

    // MARK: - The status vocabulary

    @Test("inserted, updated and duplicate are terminal")
    func terminalStatuses() {
        for status in [HealthKitEntryStatus.inserted, .updated, .duplicate] {
            #expect(
                Self.accepts(postedCount: 1, Self.response([.init(index: 0, status: status)])),
                "\(status.rawValue) must let the cursor advance"
            )
        }
    }

    @Test("failed and unknown hold the cursor")
    func nonterminalStatuses() {
        for status in [HealthKitEntryStatus.failed, .unknown] {
            #expect(
                !Self.accepts(postedCount: 1, Self.response([.init(index: 0, status: status)])),
                "\(status.rawValue) must hold the cursor"
            )
        }
    }

    @Test("a status word this build cannot name decodes to unknown and holds")
    func unnamedStatusHolds() throws {
        let json = #"{"entries":[{"index":0,"status":"quarantined_for_review"}]}"#
        let decoded = try JSONDecoder().decode(HealthKitBatchResponseDTO.self, from: Data(json.utf8))
        #expect(decoded.entries.first?.status == .unknown)
        #expect(!Self.accepts(postedCount: 1, decoded))
    }

    // MARK: - The skip allowlist

    @Test("every documented skip reason is terminal")
    func allowlistedSkipReasonsAreTerminal() {
        let allowlist = MeasurementBatchAcceptance.Policy.deployedMeasurementRoute.terminalSkipReasons
        #expect(allowlist == [
            MeasurementBatchAcceptance.Reason.unmappableIdentifier,
            MeasurementBatchAcceptance.Reason.valueOutOfRange,
            MeasurementBatchAcceptance.Reason.unstableExternalId
        ])
        for reason in allowlist {
            #expect(
                Self.accepts(postedCount: 1, Self.response([.init(index: 0, status: .skipped, reason: reason)])),
                "allowlisted skip reason \(reason) must be terminal"
            )
        }
    }

    @Test("a non-allowlisted skip reason holds")
    func unknownSkipReasonHolds() {
        let response = Self.response([.init(index: 0, status: .skipped, reason: "a_brand_new_refusal")])
        #expect(!Self.accepts(postedCount: 1, response))
    }

    @Test("a skip with no reason at all holds")
    func reasonlessSkipHolds() {
        let response = Self.response([.init(index: 0, status: .skipped, reason: nil)])
        #expect(!Self.accepts(postedCount: 1, response))
    }

    @Test("a reason carried only in skipped[] still reaches the allowlist")
    func mirroredReasonIsAdopted() {
        let response = Self.response(
            [.init(index: 0, status: .skipped, reason: nil)],
            skipped: [.init(index: 0, reason: MeasurementBatchAcceptance.Reason.valueOutOfRange)]
        )
        #expect(Self.accepts(postedCount: 1, response))
    }

    @Test("a skipped[]-only index is indexed evidence, and still reason-gated")
    func skippedOnlyIndexIsReasonGated() {
        let terminal = Self.response(
            [.init(index: 0, status: .inserted)],
            skipped: [.init(index: 1, reason: MeasurementBatchAcceptance.Reason.unstableExternalId)]
        )
        #expect(Self.accepts(postedCount: 2, terminal))

        let held = Self.response(
            [.init(index: 0, status: .inserted)],
            skipped: [.init(index: 1, reason: "not_documented")]
        )
        #expect(!Self.accepts(postedCount: 2, held))
    }

    // MARK: - Index coverage

    @Test("a missing index holds")
    func missingIndexHolds() {
        let verdict = MeasurementBatchAcceptance.classify(
            postedCount: 2,
            response: Self.response([.init(index: 0, status: .inserted)])
        )
        #expect(verdict.missingIndexes == [1])
        #expect(!verdict.isCompletelyAccepted)
    }

    @Test("a repeated index holds, in entries[] and in skipped[]")
    func repeatedIndexHolds() {
        let repeatedEntry = Self.response([
            .init(index: 0, status: .inserted),
            .init(index: 0, status: .inserted)
        ])
        #expect(MeasurementBatchAcceptance.classify(postedCount: 1, response: repeatedEntry).duplicateIndexCount == 1)
        #expect(!Self.accepts(postedCount: 1, repeatedEntry))

        let repeatedSkip = Self.response(
            [.init(index: 0, status: .inserted)],
            skipped: [
                .init(index: 0, reason: MeasurementBatchAcceptance.Reason.valueOutOfRange),
                .init(index: 0, reason: MeasurementBatchAcceptance.Reason.valueOutOfRange)
            ]
        )
        #expect(!Self.accepts(postedCount: 1, repeatedSkip))
    }

    @Test("an out-of-range index holds")
    func outOfRangeIndexHolds() {
        let response = Self.response([
            .init(index: 0, status: .inserted),
            .init(index: 99, status: .inserted)
        ])
        let verdict = MeasurementBatchAcceptance.classify(postedCount: 1, response: response)
        #expect(verdict.outOfRangeIndexCount == 1)
        #expect(!verdict.isCompletelyAccepted)
    }

    @Test("an empty batch is complete by construction")
    func emptyBatchIsAccepted() {
        #expect(Self.accepts(postedCount: 0, Self.response([])))
    }

    // MARK: - superseded_in_batch

    @Test("a duplicate without the supersession reason stays plainly terminal")
    func plainDuplicateIsTerminal() {
        let response = Self.response([.init(index: 0, status: .duplicate, reason: "already_present")])
        #expect(Self.accepts(postedCount: 1, externalIds: ["sample-0"], response))
    }

    @Test("supersession is accepted for one stable stat identity with a later terminal row")
    func supersessionAccepted() {
        for successor in [HealthKitEntryStatus.inserted, .updated] {
            let response = Self.response([
                .init(index: 0, status: .duplicate, reason: MeasurementBatchAcceptance.Reason.supersededInBatch),
                .init(index: 1, status: successor)
            ])
            #expect(
                Self.accepts(postedCount: 2, externalIds: [Self.statIdentity(), Self.statIdentity()], response),
                "a later \(successor.rawValue) row of the same stat identity must complete the batch"
            )
        }
    }

    @Test("supersession is refused when the successor is missing, reordered, or nonterminal")
    func supersessionRefusedStructurally() {
        let ids = [Self.statIdentity(), Self.statIdentity()]

        // No successor at all.
        let alone = Self.response([
            .init(index: 0, status: .duplicate, reason: MeasurementBatchAcceptance.Reason.supersededInBatch)
        ])
        #expect(!Self.accepts(postedCount: 1, externalIds: [Self.statIdentity()], alone))

        // The winner is at an EARLIER index — the server's own rule is that the
        // later row wins, so this shape is not the documented supersession.
        let reordered = Self.response([
            .init(index: 0, status: .updated),
            .init(index: 1, status: .duplicate, reason: MeasurementBatchAcceptance.Reason.supersededInBatch)
        ])
        #expect(!Self.accepts(postedCount: 2, externalIds: ids, reordered))

        // The successor itself did not land.
        for successor in [HealthKitEntryStatus.failed, .unknown, .skipped, .duplicate] {
            let response = Self.response([
                .init(index: 0, status: .duplicate, reason: MeasurementBatchAcceptance.Reason.supersededInBatch),
                .init(index: 1, status: successor)
            ])
            #expect(
                !Self.accepts(postedCount: 2, externalIds: ids, response),
                "a \(successor.rawValue) successor is not evidence that the earlier row's value landed"
            )
        }
    }

    @Test("supersession is refused for a mismatched or non-stat identity")
    func supersessionRefusedByIdentity() {
        let response = Self.response([
            .init(index: 0, status: .duplicate, reason: MeasurementBatchAcceptance.Reason.supersededInBatch),
            .init(index: 1, status: .updated)
        ])
        // Same shape, different stable identities.
        #expect(!Self.accepts(
            postedCount: 2,
            externalIds: [Self.statIdentity("2026-08-14"), Self.statIdentity("2026-08-15")],
            response
        ))
        // Same identity, but a per-sample UUID cannot be superseded: it is not an
        // upsert key, so a duplicate of it proves nothing about a later row.
        #expect(!Self.accepts(
            postedCount: 2,
            externalIds: ["00000000-0000-4000-8000-000000000001", "00000000-0000-4000-8000-000000000001"],
            response
        ))
    }

    @Test("a supersession whose successor index is repeated holds")
    func supersessionWithRepeatedSuccessorHolds() {
        let response = Self.response([
            .init(index: 0, status: .duplicate, reason: MeasurementBatchAcceptance.Reason.supersededInBatch),
            .init(index: 1, status: .updated),
            .init(index: 1, status: .updated)
        ])
        #expect(!Self.accepts(postedCount: 2, externalIds: [Self.statIdentity(), Self.statIdentity()], response))
    }

    @Test("an external-id list of the wrong length degrades to the structural rule, never to acceptance of the rest")
    func mismatchedIdentityListDegrades() {
        // One id for a two-row batch: the identities cannot be trusted, so the
        // supersession falls back to structure — but nothing else weakens.
        let response = Self.response([
            .init(index: 0, status: .duplicate, reason: MeasurementBatchAcceptance.Reason.supersededInBatch),
            .init(index: 1, status: .failed)
        ])
        #expect(!Self.accepts(postedCount: 2, externalIds: [Self.statIdentity()], response))
    }

    // MARK: - The error stays privacy-safe

    @Test("the acceptance error carries aggregate counts and no identifier")
    func errorIsAggregateOnly() throws {
        let response = Self.response([
            .init(index: 0, status: .failed, reason: "persistence_error")
        ])
        var thrown: MeasurementBatchAcceptanceError?
        do {
            try MeasurementBatchAcceptance.validate(
                postedCount: 2,
                postedExternalIds: ["stats:HKQuantityTypeIdentifierStepCount:2026-08-14", "secret-uuid"],
                response: response
            )
        } catch let error as MeasurementBatchAcceptanceError {
            thrown = error
        }
        let description = try #require(thrown).description
        #expect(description.contains("posted=2"))
        #expect(description.contains("rejected=1"))
        #expect(description.contains("missing=1"))
        #expect(!description.contains("secret-uuid"))
        #expect(!description.contains("stats:"))
        #expect(!description.contains("persistence_error"))
    }
}
