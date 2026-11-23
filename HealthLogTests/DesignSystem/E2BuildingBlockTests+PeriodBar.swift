@testable import HealthLog
import SwiftUI
import Testing

extension E2BuildingBlockTests {
    @Test("the period capsule is compact from the first accessibility size on")
    func periodCapsuleCompact() throws {
        typealias Control = HLFloatingPeriodControl<HLTimeRange>
        #expect(Control.isCompact(at: .accessibility1))
        #expect(!Control.isCompact(at: .xxxLarge))
        let compact = try DesignContractMeasure.size(
            of: Control(selection: .constant(.standard)), width: nil, typeSize: .accessibility3
        )
        #expect(compact.width < Control.maxWidth, "the capsule hugs the chosen period: \(compact.width)")
    }

    @Test("a page with the period bar still renders its content")
    func periodBarRenders() throws {
        let page = DesignContractMeasure.marker
            .frame(height: 40)
            .frame(maxHeight: .infinity, alignment: .top)
            .hlPeriodBar(selection: .constant(HLTimeRange.standard))
            .frame(height: 300)
        let (frame, _) = try DesignContractMeasure.markerFrame(in: page, width: 320)
        #expect(frame.height == 40)
    }
}

extension E2BuildingBlockTests {
    @Test("the period segments are full hit targets and the lens glides only with motion on")
    func periodSegments() throws {
        typealias Segments = HLGlassPeriodSegments<HLTimeRange>
        #expect(Segments.segmentHeight == HLHitTarget.minimum)
        #expect(Segments.lensAnimation(reduceMotion: true) == nil)
        #expect(Segments.lensAnimation(reduceMotion: false) != nil)
        // Six periods on one line inside the capsule, at the standard size
        // and at the largest one before the menu.
        for typeSize in [DynamicTypeSize.large, .xxxLarge] {
            let bar = try DesignContractMeasure.size(
                of: HLFloatingPeriodControl(selection: .constant(HLTimeRange.standard)), width: 402, typeSize: typeSize
            )
            #expect(bar.height <= HLHitTarget.minimum + HLSpace.sm + 1, "the bar stays one line: \(bar.height)")
        }
        let natural = try DesignContractMeasure.size(
            of: HLFloatingPeriodControl(selection: .constant(HLTimeRange.standard)), width: nil, typeSize: .large
        )
        #expect(natural.width <= HLFloatingPeriodControl<HLTimeRange>.maxWidth + 2 * HLSpace.lg)
    }
}
