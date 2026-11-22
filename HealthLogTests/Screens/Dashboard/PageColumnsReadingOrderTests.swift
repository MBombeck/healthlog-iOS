@testable import HealthLog
import Testing

/// VoiceOver reads a two-column page the way it is meant: the pair is one
/// container, so the page's head stays first, and only side by side does the
/// leading column get a priority over the trailing one. Stacked or single,
/// every column keeps 0 and the order is the order on screen, as on the
/// phone. The spoken order itself is a device check: in the test process
/// SwiftUI builds no accessibility tree while VoiceOver is off.
@Suite("Page columns reading order")
struct PageColumnsReadingOrderTests {
    @Test("only side by side does the leading column get a priority")
    func priorities() {
        #expect(HLPageColumns.sideBySide.readingPriority(leading: true) == 1)
        #expect(HLPageColumns.sideBySide.readingPriority(leading: false) == 0)
        #expect(HLPageColumns.single.readingPriority(leading: true) == 0)
        #expect(HLPageColumns.single.readingPriority(leading: false) == 0)
    }
}
