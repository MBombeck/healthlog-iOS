import Foundation
import Testing

#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// The strip scrolls to the pill that carries the selection. A category with
/// one member renders that member as its own pill, so the anchor must come from
/// the rendered entries, not from the taxonomy alone.
@Suite("Insights strip — scroll anchor of the selected pill")
struct InsightsStripAnchorTests {
    private static func entries(_ ordered: [InsightsTabSelection]) -> [InsightsStripEntry] {
        InsightsStripEntry.strip(from: ordered)
    }

    @Test("the only member of a category is its own pill")
    func singleMemberAnchorsOnItself() {
        let ordered: [InsightsTabSelection] = [.overview, .metric(.weight), .metric(.spo2), .metric(.sleep)]
        let anchor = InsightsMetricTabStrip.scrollAnchor(forSelection: .metric(.spo2), in: Self.entries(ordered))
        #expect(anchor == .selection(.metric(.spo2)))
    }

    @Test("a member of a category with two members anchors on the category pill")
    func groupedMemberAnchorsOnCategory() {
        let ordered: [InsightsTabSelection] = [.overview, .metric(.spo2), .metric(.bodyTemperature)]
        let anchor = InsightsMetricTabStrip.scrollAnchor(forSelection: .metric(.bodyTemperature), in: Self.entries(ordered))
        #expect(anchor == .category(.vitals))
    }

    @Test("a special page as the only member of its category is its own pill")
    func singleSpecialMemberAnchorsOnItself() {
        let ordered: [InsightsTabSelection] = [.overview, .metric(.weight), .special(.workouts)]
        let anchor = InsightsMetricTabStrip.scrollAnchor(forSelection: .special(.workouts), in: Self.entries(ordered))
        #expect(anchor == .selection(.special(.workouts)))
    }

    @Test("every selection of a mixed strip anchors on a pill the strip renders")
    func everyAnchorIsRendered() {
        let ordered: [InsightsTabSelection] = [
            .overview, .metric(.weight), .metric(.bloodPressure),
            .metric(.spo2), .metric(.bodyTemperature),
            .metric(.steps), .special(.workouts),
            .metric(.sleep), .special(.mood), .special(.medications)
        ]
        let rendered = Self.entries(ordered)
        let anchors = Set(rendered.map(InsightsMetricTabStrip.scrollAnchor(for:)))
        for selection in ordered {
            let anchor = InsightsMetricTabStrip.scrollAnchor(forSelection: selection, in: rendered)
            #expect(anchors.contains(anchor), "\(selection) anchors on \(anchor), which no rendered pill carries")
        }
    }
}
