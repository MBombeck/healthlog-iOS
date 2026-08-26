import Foundation
@testable import HealthLog
import Testing

/// Pins the pure point ordering behind the shared ``HistoryLineChart`` (extracted
/// from the mental-health instrument detail so mental-health and the Vorsorge
/// detail sheet share one chart source). The view draws left = older → right =
/// newest and annotates only `ordered(_:).last`, so the sort + last-point
/// contract is the substance to pin without a chart host.
@Suite("HistoryLineChart point logic")
struct HistoryLineChartTests {
    private func point(_ id: String, _ secondsFromEpoch: TimeInterval, _ value: Double) -> HistoryLineChart.Point {
        HistoryLineChart.Point(id: id, date: Date(timeIntervalSince1970: secondsFromEpoch), value: value)
    }

    @Test("ordered sorts oldest → newest regardless of input order")
    func ordersOldestToNewest() {
        let unsorted = [
            point("c", 300, 12),
            point("a", 100, 8),
            point("b", 200, 10)
        ]
        let ordered = HistoryLineChart.ordered(unsorted)
        #expect(ordered.map(\.id) == ["a", "b", "c"])
    }

    @Test("the most-recent point is ordered.last (the annotated / larger symbol)")
    func lastPointIsNewest() {
        let points = [
            point("old", 100, 4),
            point("new", 999, 20),
            point("mid", 500, 11)
        ]
        let ordered = HistoryLineChart.ordered(points)
        #expect(ordered.last?.id == "new")
        // Every non-last point precedes the newest in time.
        #expect(ordered.dropLast().allSatisfy { $0.date < (ordered.last?.date ?? .distantPast) })
    }

    @Test("a single point is trivially its own last (one dot, still ordered)")
    func singlePoint() {
        let ordered = HistoryLineChart.ordered([point("only", 42, 7)])
        #expect(ordered.count == 1)
        #expect(ordered.last?.id == "only")
    }

    @Test("an empty series orders to empty (no chart is drawn)")
    func emptySeries() {
        #expect(HistoryLineChart.ordered([]).isEmpty)
    }
}
