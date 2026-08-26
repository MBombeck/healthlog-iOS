import Foundation
@testable import HealthLog
import Testing

@Suite("Workouts — complete batch acceptance")
struct WorkoutImportAcceptanceTests {
    @Test("inserted, duplicate and enriched cover every posted index")
    func acceptedTerminalStatuses() throws {
        let response = WorkoutBatchResponseDTO(
            processed: 3,
            inserted: 1,
            duplicates: 1,
            entries: [
                .init(index: 2, status: .enriched),
                .init(index: 0, status: .inserted),
                .init(index: 1, status: .duplicate)
            ]
        )

        try WorkoutBatchAcceptance.validate(postedCount: 3, response: response)
    }

    @Test("a skipped entry rejects the whole posted chunk")
    func skippedRejectsChunk() {
        let response = WorkoutBatchResponseDTO(
            processed: 2,
            inserted: 1,
            duplicates: 0,
            entries: [
                .init(index: 0, status: .inserted),
                .init(index: 1, status: .skipped, reason: "invalid samples for user@example.com")
            ]
        )

        let error = captureFailure(postedCount: 2, response: response)
        #expect(error?.rejectedCount == 1)
        #expect(error?.missingCount == 0)
        #expect(error?.description.contains("user@example.com") == false)
        #expect(error?.description.contains("invalid samples") == false)
    }

    @Test("an absent per-entry result rejects the chunk")
    func missingEntryRejectsChunk() {
        let response = WorkoutBatchResponseDTO(
            processed: 2,
            inserted: 1,
            duplicates: 0,
            entries: [.init(index: 0, status: .inserted)]
        )

        let error = captureFailure(postedCount: 2, response: response)
        #expect(error?.acceptedCount == 1)
        #expect(error?.missingCount == 1)
    }

    @Test("duplicate and out-of-range indices reject ambiguous coverage")
    func invalidIndicesRejectChunk() {
        let response = WorkoutBatchResponseDTO(
            processed: 3,
            inserted: 3,
            duplicates: 0,
            entries: [
                .init(index: 0, status: .inserted),
                .init(index: 0, status: .inserted),
                .init(index: 3, status: .inserted)
            ]
        )

        let error = captureFailure(postedCount: 3, response: response)
        #expect(error?.duplicateIndexCount == 1)
        #expect(error?.outOfRangeIndexCount == 1)
        #expect(error?.missingCount == 2)
    }

    @Test("an additive unknown status is decoded but is not accepted silently")
    func unknownStatusRejectsChunk() {
        let response = WorkoutBatchResponseDTO(
            processed: 1,
            inserted: 0,
            duplicates: 0,
            entries: [.init(index: 0, status: .init(rawValue: "deferred"), reason: "queued elsewhere")]
        )

        let error = captureFailure(postedCount: 1, response: response)
        #expect(error?.rejectedCount == 1)
        #expect(error?.acceptedCount == 0)
    }

    private func captureFailure(
        postedCount: Int,
        response: WorkoutBatchResponseDTO
    ) -> WorkoutBatchAcceptanceError? {
        do {
            try WorkoutBatchAcceptance.validate(postedCount: postedCount, response: response)
            Issue.record("expected incomplete batch acceptance to throw")
            return nil
        } catch let error as WorkoutBatchAcceptanceError {
            return error
        } catch {
            Issue.record("expected WorkoutBatchAcceptanceError, got \(String(describing: error))")
            return nil
        }
    }
}
