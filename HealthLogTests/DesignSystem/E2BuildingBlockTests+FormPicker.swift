@testable import HealthLog
import SwiftUI
import Testing

extension E2BuildingBlockTests {
    private static let goals = ["Allgemeine Gesundheit", "Schwangerschaft planen", "Verhütung"]

    private func picker() -> some View {
        HLFormPicker(
            title: Text(verbatim: "Ziel"),
            selection: .constant(Self.goals[0]),
            options: Self.goals
        ) { Text(verbatim: $0) }
    }

    @Test("the form picker stacks title and value from the first accessibility size on")
    func formPickerStacks() {
        #expect(HLFormPicker<String>.stacks(at: .accessibility1))
        #expect(HLFormPicker<String>.stacks(at: .accessibility4))
        #expect(!HLFormPicker<String>.stacks(at: .xxxLarge))
    }

    @Test("at accessibility4 the whole value is shown under the title instead of cut in the middle")
    func formPickerShowsWholeValue() throws {
        let typeSize = DynamicTypeSize.accessibility4
        let stacked = try DesignContractMeasure.size(of: picker(), width: 320, typeSize: typeSize)
        let title = try DesignContractMeasure.size(
            of: Text(verbatim: "Ziel").font(HLRowTitle.font), width: 320, typeSize: typeSize
        )
        let value = try DesignContractMeasure.size(
            of: Text(verbatim: Self.goals[0]).font(HLRowValue.Emphasis.setting.font), width: 290, typeSize: typeSize
        )
        #expect(stacked.height >= title.height + value.height, "title over the full value: \(stacked.height)")
        let regular = try DesignContractMeasure.size(of: picker(), width: 320)
        #expect(regular.height >= HLLayout.rowMinHeight)
        #expect(regular.height < stacked.height, "below the accessibility sizes it is one row")
    }
}
