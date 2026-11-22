@testable import HealthLog
import SwiftUI
import Testing

extension E2BuildingBlockTests {
    @Test("an empty state stands in the middle of a tall area, inside the page margin")
    func emptyStateCentred() throws {
        let lockup = HLEmptyState(icon: "figure.run", title: Text(verbatim: "No workouts yet")) {
            DesignContractMeasure.marker.frame(maxWidth: .infinity).frame(height: 10)
        }
        .frame(height: 600)
        let (frame, size) = try DesignContractMeasure.markerFrame(in: lockup, width: 320)
        #expect(size.height == 600)
        #expect(
            frame.minY > size.height / 3 && frame.maxY < size.height * 2 / 3,
            "the lockup stands in the middle, the action at \(frame.minY)"
        )
        #expect(frame.minX == HLLayout.pageMargin, "text and action keep the page margin")
        #expect(frame.maxX == 320 - HLLayout.pageMargin)
    }

    @Test("an empty state's button is never wider than the action width")
    func emptyStateButtonWidth() throws {
        let lockup = HLEmptyState(icon: "folder", title: Text(verbatim: "No documents yet")) {
            DesignContractMeasure.marker.frame(maxWidth: .infinity).frame(height: 10)
        }
        let (frame, _) = try DesignContractMeasure.markerFrame(in: lockup, width: 1000)
        #expect(frame.width == HLLayout.actionMaxWidth)
        #expect(abs(frame.midX - 500) < 1, "the button stands centred")
    }
}
