@testable import HealthLog
import SwiftUI
import Testing

extension E2BuildingBlockTests {
    private func captionLine(at typeSize: DynamicTypeSize) -> CGFloat {
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(typeSize))
        return UIFont.preferredFont(forTextStyle: .caption1, compatibleWith: traits).lineHeight
    }

    @Test("the compliance bar stacks its rate under the label at the accessibility sizes")
    func complianceBarStacks() throws {
        #expect(HLComplianceBar.stacks(at: .accessibility1))
        #expect(!HLComplianceBar.stacks(at: .xxxLarge))
        let typeSize = DynamicTypeSize.accessibility3
        let bar = try DesignContractMeasure.size(of: HLComplianceBar(label: "7 days", rate: 92), typeSize: typeSize)
        #expect(bar.height >= 2 * captionLine(at: typeSize), "label and rate stand on two lines")
    }

    @Test("the in-range rail keeps its whole title at the accessibility sizes")
    func rangeBandStacks() throws {
        #expect(RangeBandRow.stacks(at: .accessibility1))
        #expect(!RangeBandRow.stacks(at: .xxxLarge))
        let typeSize = DynamicTypeSize.accessibility3
        let long = RangeBandRow(share: 84, window: "the last ninety days with a measurement")
        let row = try DesignContractMeasure.size(of: long, typeSize: typeSize)
        let short = try DesignContractMeasure.size(of: RangeBandRow(share: 84), typeSize: typeSize)
        #expect(short.height >= 2 * captionLine(at: typeSize), "title and share stand on two lines")
        #expect(row.height > short.height, "a long title wraps instead of being cut")
    }
}
