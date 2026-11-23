import Foundation
@testable import HealthLog
import Testing

/// The score glance is rebuilt with a fresh `resolvedAt` on every dashboard
/// load. An unchanged score must not cost a write and a timeline reload.
@Suite("Health score glance diff")
@MainActor
struct HealthScoreGlanceDiffTests {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeWriter() -> (WidgetSnapshotWriter, WidgetSnapshotStore) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("score-diff-\(UUID().uuidString).json")
        let store = WidgetSnapshotStore(url: url)
        return (WidgetSnapshotWriter(store: store), store)
    }

    @Test("Content comparison ignores the resolve time")
    func sameContentIgnoresResolveTime() {
        let first = WidgetSnapshot.HealthScoreGlance(score: 72, band: "green", resolvedAt: base)
        let later = WidgetSnapshot.HealthScoreGlance(score: 72, band: "green", resolvedAt: base.addingTimeInterval(600))
        #expect(first.hasSameContent(as: later))
        #expect(!first.hasSameContent(as: .init(score: 73, band: "green", resolvedAt: base)))
        #expect(!first.hasSameContent(as: .init(score: 72, band: "yellow", resolvedAt: base)))
        #expect(!first.hasSameContent(as: .init(score: 72, band: "green", resolvedAt: base, configured: true)))
    }

    @Test("Re-resolving the same score skips the write")
    func unchangedScoreSkipsWrite() async {
        let (writer, store) = makeWriter()
        writer.refreshHealthScore(.init(score: 72, band: "green", resolvedAt: base), now: base)
        await writer.drainPendingWrites()
        let firstStamp = store.read()?.generatedAt
        #expect(firstStamp != nil)

        let later = base.addingTimeInterval(600)
        writer.refreshHealthScore(.init(score: 72, band: "green", resolvedAt: later), now: later)
        await writer.drainPendingWrites()
        #expect(store.read()?.generatedAt == firstStamp)
    }

    @Test("A new score still writes through")
    func changedScoreWrites() async {
        let (writer, store) = makeWriter()
        writer.refreshHealthScore(.init(score: 72, band: "green", resolvedAt: base), now: base)
        await writer.drainPendingWrites()

        let later = base.addingTimeInterval(600)
        writer.refreshHealthScore(.init(score: 60, band: "yellow", resolvedAt: later), now: later)
        await writer.drainPendingWrites()
        #expect(store.read()?.healthScore?.score == 60)
        #expect(store.read()?.generatedAt == later)
    }

    @Test("Clearing the score writes through")
    func clearedScoreWrites() async {
        let (writer, store) = makeWriter()
        writer.refreshHealthScore(.init(score: 72, band: "green", resolvedAt: base), now: base)
        await writer.drainPendingWrites()
        writer.refreshHealthScore(nil, now: base.addingTimeInterval(60))
        await writer.drainPendingWrites()
        #expect(store.read()?.healthScore == nil)
    }
}
