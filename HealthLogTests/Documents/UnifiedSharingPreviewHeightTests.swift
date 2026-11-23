import CoreGraphics
@testable import HealthLog
import Testing

/// The inline preview of the doctor report: 280 pt on a phone as before,
/// a reading size where the column is wide.
@Suite("Report preview height")
struct UnifiedSharingPreviewHeightTests {
    @Test("a phone's card keeps the 280 pt, measured or not", arguments: [nil, 0, 280, 376, 440, 479] as [CGFloat?])
    func phone(width: CGFloat?) {
        #expect(UnifiedSharingResultSection.previewHeight(width: width) == 280)
    }

    @Test("a wide column shows the report at a reading size, never over 640")
    func wide() {
        #expect(UnifiedSharingResultSection.previewHeight(width: 480) == 432)
        #expect(UnifiedSharingResultSection.previewHeight(width: 656) == 590)
        #expect(UnifiedSharingResultSection.previewHeight(width: 1000) == 640)
    }

    @Test("the height never shrinks as the column grows", arguments: AdaptiveWidths.all)
    func monotonic(window: CGFloat) {
        let narrow = UnifiedSharingResultSection.previewHeight(width: AdaptiveWidths.content(window) - 32)
        let wide = UnifiedSharingResultSection.previewHeight(width: AdaptiveWidths.content(window))
        #expect(wide >= narrow)
    }
}
