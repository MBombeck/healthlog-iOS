import Foundation
@testable import HealthLog
import Testing

@Suite("Illness presentation")
struct IllnessPresentationTests {
    @Test("Same-status children nest while orphans and cross-status links remain visible")
    func episodeGroupingPreservesEveryRow() {
        let activeParent = episode("parent")
        let nested = episode("nested", parent: "parent")
        let orphan = episode("orphan", parent: "missing")
        let resolvedParent = episode("resolved-parent", resolved: true)
        let crossStatus = episode("cross-status", parent: "resolved-parent")
        let resolvedChild = episode("resolved-child", parent: "resolved-parent", resolved: true)
        let input = [nested, orphan, activeParent, crossStatus, resolvedChild, resolvedParent]

        let groups = IllnessPresentation.groupEpisodes(input)

        #expect(groups.map(\.parent.id) == ["orphan", "parent", "cross-status", "resolved-parent"])
        #expect(groups.first(where: { $0.parent.id == "parent" })?.children.map(\.id) == ["nested"])
        #expect(groups.first(where: { $0.parent.id == "resolved-parent" })?.children.map(\.id) == ["resolved-child"])
        #expect(groups.flatMap { [$0.parent.id] + $0.children.map(\.id) }.sorted() == input.map(\.id).sorted())
    }

    @Test("Functional-impact labels use the shared plain-language scale")
    func impactLabels() {
        #expect(IllnessPresentation.impactLabel(for: 0) == "Voll belastbar")
        #expect(IllnessPresentation.impactLabel(for: 1) == "Leicht eingeschränkt")
        #expect(IllnessPresentation.impactLabel(for: 2) == "Überwiegend ruhend")
        #expect(IllnessPresentation.impactLabel(for: 3) == "Bettlägerig")
        #expect(IllnessPresentation.impactLabel(for: 4) == nil)
    }

    @Test("Settled requires every rendered finding block, including returns, to be empty")
    func settledPredicateIncludesReturns() {
        let empty = correlationValue()
        let withReturn = correlationValue(returns: [
            IllnessVitalReturn(type: "HRV", returnedDay: "2026-06-03", gapDays: 1)
        ])

        #expect(IllnessPresentation.isSettled(empty))
        #expect(!IllnessPresentation.isSettled(withReturn))
        #expect(!IllnessPresentation.isSettled(correlationValue(recoveryGapDays: 0)))
    }

    @Test("Delete request yields no target until the user confirms")
    func deleteGuardRequiresConfirmation() {
        let target = episode("delete-me")
        var guardState = IllnessDeleteConfirmation()

        guardState.request(target)
        #expect(guardState.candidate?.id == "delete-me")
        guardState.cancel()
        #expect(guardState.confirm() == nil)

        guardState.request(target)
        #expect(guardState.confirm()?.id == "delete-me")
        #expect(guardState.candidate == nil)
    }

    private func episode(
        _ id: String,
        parent: String? = nil,
        resolved: Bool = false
    ) -> IllnessEpisodeDTO {
        IllnessEpisodeDTO(
            id: id,
            label: id,
            type: .infection,
            lifecycle: parent == nil ? .acute : .flare,
            onsetAt: "2026-06-01T08:00:00Z",
            resolvedAt: resolved ? "2026-06-03T08:00:00Z" : nil,
            parentConditionId: parent,
            note: nil,
            createdAt: "2026-06-01T08:00:00Z",
            updatedAt: "2026-06-01T08:00:00Z"
        )
    }

    private func correlationValue(
        returns: [IllnessVitalReturn] = [],
        recoveryGapDays: Double? = nil
    ) -> IllnessCorrelationValue {
        IllnessCorrelationValue(
            episodeId: "episode",
            preOnset: [],
            nadir: [],
            returns: returns,
            recoveryGapDays: recoveryGapDays,
            feltBetterDay: nil,
            gapDriverType: nil,
            redFlags: [],
            sleepContext: nil
        )
    }
}
