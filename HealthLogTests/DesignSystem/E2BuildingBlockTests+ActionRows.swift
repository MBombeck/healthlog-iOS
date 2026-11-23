@testable import HealthLog
import SwiftUI
import Testing

extension E2BuildingBlockTests {
    @Test("at the accessibility sizes the indicator stands at the title's first line, not beside the symbol")
    func indicatorAtFirstLine() throws {
        let symbolHeight: CGFloat = 40
        let row = HLRowLayout(
            title: Text(verbatim: "Benachrichtigungen und Erinnerungen für Medikamente"),
            subtitle: nil,
            indicator: .symbol("square.fill"),
            configuration: .action(titleTint: HLText.primary, indicatorTint: DesignContractMeasure.marker),
            leading: { Color.clear.frame(width: 26, height: symbolHeight) },
            trailing: { EmptyView() }
        )
        let typeSize = DynamicTypeSize.accessibility3
        let (frame, size) = try DesignContractMeasure.markerFrame(in: row, width: 320, typeSize: typeSize)
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(typeSize))
        let font = UIFont.preferredFont(forTextStyle: .subheadline, compatibleWith: traits)
        let firstLineMiddle = symbolHeight + HLSpace.xs + font.ascender - font.capHeight / 2
        #expect(frame.minY > symbolHeight / 2, "the indicator no longer sits beside the symbol")
        #expect(abs(frame.midY - firstLineMiddle) <= 6, "indicator at \(frame.midY), first line at \(firstLineMiddle)")
        #expect(frame.midY < size.height / 2, "the indicator does not drop to the middle of a long title")
    }
}
