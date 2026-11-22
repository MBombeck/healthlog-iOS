@testable import HealthLog
import SwiftUI
import Testing

extension E2BuildingBlockTests {
    private func header(subtitle: LocalizedStringKey?) -> some View {
        HLTabHeader("Insights", subtitle: subtitle) {
            DesignContractMeasure.marker.frame(width: 60, height: 30)
        }
        // The inline form, the one that lays the actions out under the title.
        .environment(\.hlTabHeaderActionPlacement, .inline)
    }

    @Test("at the accessibility sizes the actions stand right under the title, at the trailing edge, on every page alike")
    func headerActionsUnderTitle() throws {
        let typeSize = DynamicTypeSize.accessibility2
        let plain = try DesignContractMeasure.markerFrame(in: header(subtitle: nil), width: 320, typeSize: typeSize)
        let withLine = try DesignContractMeasure.markerFrame(
            in: header(subtitle: "Your health values over time"),
            width: 320,
            typeSize: typeSize
        )
        #expect(abs(plain.frame.maxX - 320) <= 1, "the group ends at the trailing edge: \(plain.frame)")
        #expect(plain.frame.minY == withLine.frame.minY, "a line under the title does not push the group down")
        #expect(withLine.size.height > plain.size.height, "the line follows under the group")
    }
}
