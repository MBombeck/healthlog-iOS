import Foundation
@testable import HealthLog
import SwiftUI
import Testing

/// v0.12 W4-3 — locks the mood "analysis" single-implementation contract.
///
/// Before W4-3 the seven analysis sub-views shipped twice — once in
/// `MoodAnalysisScreen` (More → Stimmung) and once in `InsightsMoodPage`
/// (Insights → Stimmung) — in the same order with separately-maintained period
/// controls + sheet wiring (double-maintenance). W4-3 extracts the seven-section
/// sequence into one shared `MoodAnalysisContent` body that both hosts delegate
/// to. This suite pins that the shared body emits EXACTLY the seven sections, in
/// order 0…6, so a regression that drops or re-orders a section (or that
/// re-introduces a divergent second copy) is caught.
@MainActor
@Suite("MoodAnalysisContent — one shared seven-section body")
struct MoodAnalysisContentTests {
    /// Renders the shared content once and records every section index the
    /// `section` decorator is handed. Both hosts route through this exact body,
    /// so the recorded order IS the contract both surfaces share.
    private func recordedSectionIndices(showsRecentSection: Bool = true) throws -> [Int] {
        let api = StubAPIClient()
        let outbox = try OutboxQueue(inMemory: true)
        let store = MoodStore(repo: MoodRepository(api: api, outbox: outbox))
        let recorder = IndexRecorder()
        let content = MoodAnalysisContent(
            period: .days30,
            editing: .constant(nil),
            showFullHistory: .constant(false),
            showsRecentSection: showsRecentSection
        ) { index, view in
            recorder.indices.append(index)
            return view
        }
        .environment(store)

        // Force body evaluation without a UIWindow host. The `section` closure
        // runs during body evaluation, populating the recorder.
        let renderer = ImageRenderer(content: content)
        _ = renderer.uiImage
        return recorder.indices
    }

    @Test("emits exactly seven sections")
    func emitsSevenSections() throws {
        #expect(try recordedSectionIndices().count == 7)
    }

    @Test("section indices are 0…6 in order (hero → heatmap → trend → stability → tags → patterns → recent)")
    func sectionIndicesAreOrdered() throws {
        #expect(try recordedSectionIndices() == [0, 1, 2, 3, 4, 5, 6])
    }

    /// v0.14.4 E2 — the Insights Mood page opts out of the inline recent-entries
    /// section (`showsRecentSection: false`); it replaces it with the canonical
    /// bottom-of-page "Show all measurements" drill-down. The shared body must
    /// then emit only sections 0…5 (no index 6).
    @Test("recent section (index 6) is dropped when the host opts out (E2)")
    func recentSectionDroppable() throws {
        #expect(try recordedSectionIndices(showsRecentSection: false) == [0, 1, 2, 3, 4, 5])
    }

    // MARK: - Phase 09 / 09-04

    /// The shared body no longer *produces* an analysis; it draws one.
    ///
    /// Two things are pinned together on purpose. The engine must run zero times
    /// during a body evaluation — but zero is also what a body that never ran
    /// reports, so the section decorator, which is called from inside the body
    /// once per section, is the witness that it did. And the sections it emits
    /// while the analysis is still unresolved are the same sections it emits
    /// afterwards: every card is sample-gated, so "not yet" self-suppresses
    /// exactly the way "none" already did, and no host sees a third state.
    @Test("the shared body emits its sections without running the analysis engine")
    func bodyDrawsASnapshotAndComputesNothing() throws {
        let ledger = Phase09MoodAnalysisLedger()
        let api = StubAPIClient()
        let outbox = try OutboxQueue(inMemory: true)
        let store = MoodStore(repo: MoodRepository(api: api, outbox: outbox))
        store.replaceEntriesForTesting(Phase09MoodFixture.entries(count: 120, endingAt: .now))
        let recorder = IndexRecorder()
        let content = MoodAnalysisContent(
            period: .days30,
            editing: .constant(nil),
            showFullHistory: .constant(false),
            showsRecentSection: false,
            analysis: ledger.engine
        ) { index, view in
            recorder.indices.append(index)
            return view
        }
        .environment(store)

        let renderer = ImageRenderer(content: content)
        _ = renderer.uiImage

        #expect(recorder.indices == [0, 1, 2, 3, 4, 5], "the unresolved body emits the same sections in the same order")
        // The render's own `.task` may or may not have landed by the time this
        // line runs, so the count is not the assertion — *where* it ran is.
        // Before 09-04 this body ran six analyses on the thread that draws.
        #expect(ledger.mainThreadComputeCount == 0, "no analysis may run on the thread that draws")
    }
}

/// Reference box so the value-type `section` closure can append across renders.
private final class IndexRecorder {
    var indices: [Int] = []
}
