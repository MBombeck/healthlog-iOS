import Foundation
@testable import HealthLog
import Testing

/// **v0.15.7 W-RHYTHM-FRONTDOOR — pins the pure logic behind the Home
/// rhythm-events (ECG/AFib device-health-notifications) front-door tile.**
///
/// Two decisions keep the tile (a SwiftUI view) a thin renderer over verified
/// logic:
///
/// 1. `RhythmEventsTileModel.summary` — self-suppression gate. `nil` on an empty
///    event list (⇒ the host omits the tile, no dead/empty slab), non-nil with
///    the count + localized subtitle when there ARE events.
/// 2. `AppRouter.requestInsightsOverview` — the tile's tap routes to the Insights
///    tab AND resets its pager to the overview (where the full card lives).
@Suite("Rhythm-events front-door logic")
struct RhythmEventsTileModelTests {
    private static func event(id: String) -> RhythmEventsDTO.Event {
        RhythmEventsDTO.Event(
            id: id,
            type: "IRREGULAR_RHYTHM_NOTIFICATION",
            classification: "IRREGULAR",
            occurredAt: Date(timeIntervalSince1970: 1_700_000_000),
            source: "WITHINGS",
            deviceType: "ScanWatch"
        )
    }

    @Test("summary is nil on an empty event list (tile self-suppresses)")
    func emptySelfSuppresses() {
        #expect(RhythmEventsTileModel.summary(for: []) == nil)
    }

    @Test("summary carries the event count when there are events")
    func nonEmptyCarriesCount() throws {
        let summary = try #require(
            RhythmEventsTileModel.summary(for: [Self.event(id: "a"), Self.event(id: "b")])
        )
        #expect(summary.count == 2)
        #expect(!summary.subtitle.isEmpty)
    }

    @Test("single event still produces a (singular) summary")
    func singleEvent() throws {
        let summary = try #require(RhythmEventsTileModel.summary(for: [Self.event(id: "a")]))
        #expect(summary.count == 1)
    }

    @MainActor
    @Test("requestInsightsOverview → Insights tab, reset pager to overview")
    func routesToInsightsOverview() {
        let router = AppRouter()
        router.selectedTab = .home
        let before = router.insightsRootRequestCount
        router.requestInsightsOverview()
        #expect(router.selectedTab == .insights)
        #expect(router.insightsRootRequestCount == before + 1)
    }
}
