import Foundation
@testable import HealthLog
import Testing

/// A360-4 QoS-3 — coverage of the `AssessmentCard` state machine, in particular
/// the new terminal `failed` arm that replaces an indefinite "preparing"
/// skeleton once the warm-poll exhausts or stops on a transient error. The
/// resolution is extracted into the pure `AssessmentCard.resolveState(...)` so it
/// is testable without hosting the SwiftUI view.
@Suite("AssessmentCard — state resolution (QoS-3)")
struct AssessmentCardStateTests {
    private func preparing() -> MetricStatusDTO {
        MetricStatusDTO(hasProvider: true, text: nil, cached: false, updatedAt: nil, preparing: true)
    }

    private func ready() -> MetricStatusDTO {
        MetricStatusDTO(hasProvider: true, text: "All good.", cached: false, updatedAt: nil)
    }

    // MARK: - The QoS-3 failure arm

    @Test("preparing + failed → .failed (terminal caption, not an endless skeleton)")
    func preparingFailedTerminal() {
        let state = AssessmentCard.resolveState(
            assessment: preparing(),
            isLoading: false,
            failed: true,
            consentClosed: false,
            hasServer: true
        )
        #expect(state == .failed)
    }

    @Test("preparing + not failed → .loading (still polling)")
    func preparingStillLoading() {
        let state = AssessmentCard.resolveState(
            assessment: preparing(),
            isLoading: false,
            failed: false,
            consentClosed: false,
            hasServer: true
        )
        #expect(state == .loading)
    }

    @Test("no envelope + failed → .failed (first fetch failed before any body landed)")
    func firstFetchFailed() {
        let state = AssessmentCard.resolveState(
            assessment: nil,
            isLoading: false,
            failed: true,
            consentClosed: false,
            hasServer: true
        )
        #expect(state == .failed)
    }

    @Test("ready text wins over a failed flag — a stale-good assessment is never hidden")
    func readyBeatsFailed() {
        let state = AssessmentCard.resolveState(
            assessment: ready(),
            isLoading: false,
            failed: true,
            consentClosed: false,
            hasServer: true
        )
        #expect(state == .ready(text: "All good.", cached: false, updatedAt: nil))
    }

    // MARK: - Pre-existing arms must not regress

    @Test("no server → .standalone regardless of failed")
    func standaloneWins() {
        let state = AssessmentCard.resolveState(
            assessment: preparing(),
            isLoading: false,
            failed: true,
            consentClosed: false,
            hasServer: false
        )
        #expect(state == .standalone)
    }

    @Test("consent closed → .consentRequired wins over a preparing body")
    func consentWins() {
        let state = AssessmentCard.resolveState(
            assessment: preparing(),
            isLoading: false,
            failed: false,
            consentClosed: true,
            hasServer: true
        )
        #expect(state == .consentRequired)
    }

    @Test("insufficient body → .suppressed (sparse metric, never a failure caption)")
    func insufficientSuppressed() {
        let dto = MetricStatusDTO(
            hasProvider: true, text: nil, cached: false, updatedAt: nil, insufficient: true
        )
        let state = AssessmentCard.resolveState(
            assessment: dto,
            isLoading: false,
            failed: true,
            consentClosed: false,
            hasServer: true
        )
        #expect(state == .suppressed)
    }

    @Test("loading in flight → .loading even if a prior failure flag lingers")
    func loadingBeatsFailed() {
        let state = AssessmentCard.resolveState(
            assessment: nil,
            isLoading: true,
            failed: true,
            consentClosed: false,
            hasServer: true
        )
        #expect(state == .loading)
    }
}
