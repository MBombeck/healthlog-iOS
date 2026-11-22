@testable import HealthLog
import SwiftUI
import Testing

// MARK: - Bars of pushed pages

extension E3ActionFormTests {
    @Test("a pushed page's actions stand in one fixed order, from the title outwards")
    func pageActionOrder() {
        let actions: HLTabHeaderActions = [
            .add(label: "Add medication") {},
            .more { Text(verbatim: "Edit") },
            .share(text: "Lisinopril"),
            .filter { Text(verbatim: "Open") },
            .info(HLInfoContent(title: "Info", identifier: "e3.info", about: "About"), identifier: "e3.info"),
            .select(isOn: .constant(false))
        ]
        #expect(actions.items.map(\.role) == [.info, .filter, .select, .share, .more, .add])
        #expect(actions.items.map(\.systemImage) == [
            "info.circle", "line.3.horizontal.decrease", "checklist", "square.and.arrow.up", "ellipsis", "plus"
        ])
    }

    @Test("the tab header roles keep their order between the new ones")
    func headerRoleOrder() {
        #expect(HLTabHeaderAction.Role.allCases == [.info, .settings, .filter, .select, .share, .coach, .more, .add])
    }

    @Test("select and filter show their state; edit alone is the pencil in the more place")
    func pageActionStates() {
        #expect(HLTabHeaderAction.select(isOn: .constant(true)).isSelected)
        #expect(!HLTabHeaderAction.select(isOn: .constant(false)).isSelected)
        #expect(HLTabHeaderAction.filter(isSelected: true) { EmptyView() }.isSelected)
        let edit = HLTabHeaderAction.edit {}
        #expect(edit.role == .more)
        #expect(edit.systemImage == "pencil")
    }

    @Test("a page with bar actions still renders its content")
    func pageActionsRender() throws {
        let page = DesignContractMeasure.marker
            .frame(height: 40)
            .hlPageActions([.add(label: "Add medication") {}])
        let (frame, _) = try DesignContractMeasure.markerFrame(in: page, width: 320)
        #expect(frame.height == 40)
    }
}

// MARK: - Period choice above the chart

extension E3ActionFormTests {
    @Test("the period choice is segments, and a menu from the first accessibility size on")
    func periodPickerForm() {
        typealias Picker = HLPeriodPicker<HLTimeRange>
        #expect(!Picker.usesMenu(at: .xxxLarge))
        #expect(Picker.usesMenu(at: .accessibility1))
        #expect(HLTimeRange.allCases.map(\.days) == [1, 7, 30, 180, 365, 3650])
    }

    @Test("the period choice takes its own place in the content and covers nothing below it")
    func periodPickerInContent() throws {
        for typeSize in [DynamicTypeSize.large, .accessibility3] {
            let page = VStack(spacing: 0) {
                HLPeriodPicker(selection: .constant(HLTimeRange.standard))
                DesignContractMeasure.marker.frame(height: 40)
            }
            let (frame, size) = try DesignContractMeasure.markerFrame(in: page, width: 320, typeSize: typeSize)
            #expect(frame.minY >= 28, "the chart starts below the picker at \(typeSize): \(frame.minY)")
            #expect(frame.maxY == size.height)
        }
    }

    @Test("the menu form of the period choice is a full tap area")
    func periodMenuHeight() throws {
        let menu = try DesignContractMeasure.size(
            of: HLPeriodPicker(selection: .constant(HLTimeRange.standard)), typeSize: .accessibility5
        )
        #expect(menu.height >= HLHitTarget.minimum)
    }
}

// MARK: - Composer, pair, field, ink

extension E3ActionFormTests {
    @Test("send appears with text, stays while busy, and sends only text")
    func composerRules() {
        #expect(!HLComposerRules.canSend(text: "  \n", isBusy: false))
        #expect(HLComposerRules.canSend(text: "Wie war mein Schlaf?", isBusy: false))
        #expect(!HLComposerRules.canSend(text: "Wie war mein Schlaf?", isBusy: true))
        #expect(!HLComposerRules.showsSend(text: "", isBusy: false))
        #expect(HLComposerRules.showsSend(text: "", isBusy: true))
        #expect(HLComposerRules.lineLimit(at: .accessibility2) == 1 ... 3)
        #expect(HLComposerRules.lineLimit(at: .large) == 1 ... 6)
        #expect(HLComposerDisc.diameter == HLHitTarget.minimum - 2 * HLSpace.xs)
    }

    @Test("two equal buttons keep the order of the row when stacked")
    func pairReadingOrder() throws {
        #expect(HLButtonPairOrder.primaryFirst.stacked == [.primary, .secondary])
        #expect(HLButtonPairOrder.reading.stacked == [.secondary, .primary])
        let reading = HLButtonPair(order: .reading) {
            Color.gray.frame(height: 30)
        } secondary: {
            DesignContractMeasure.marker.frame(height: 30)
        }
        let standard = HLButtonPair {
            Color.gray.frame(height: 30)
        } secondary: {
            DesignContractMeasure.marker.frame(height: 30)
        }
        let top = try DesignContractMeasure.markerFrame(in: reading, width: 320, typeSize: .accessibility1).frame.minY
        let below = try DesignContractMeasure.markerFrame(in: standard, width: 320, typeSize: .accessibility1).frame.minY
        #expect(top == 0, "the leading (secondary) button stands on top")
        #expect(below > 0, "the main action stands on top")
    }

    @Test("a free text field writes sentences; the field plate is the recessed surface")
    func textFieldKinds() {
        #expect(HLTextField.writesProse(.text))
        #expect(!HLTextField.writesProse(.plain))
        #expect(HLTextField.plate == HLSurface.tertiary)
        #expect(HLTextField.plate != HLSurface.secondary, "a card would swallow the plate")
        #expect(HLTextField.plate != HLColor.surface)
    }

    @Test("an identifier value in a stat row breaks like an identifier and renders")
    func identifierStatRow() throws {
        let row = try DesignContractMeasure.size(
            of: HLSettingsStatRow(label: Text(verbatim: "Server"), value: "uitest.hermetic.local", isIdentifier: true),
            typeSize: .accessibility3
        )
        #expect(row.height >= HLLayout.rowMinHeight)
        #expect(HLIdentifierText("a.b", ink: HLText.secondary).ink == HLText.secondary)
        #expect(HLIdentifierText("a.b").ink == HLText.primary)
    }

    @Test("the edge fade of a chip strip is the page margin long")
    func edgeFadeLength() {
        #expect(HLEdgeFade.length == HLLayout.pageMargin)
    }

    @Test("the value axis thins out to three ticks from the first accessibility size on")
    func axisThinning() {
        #expect(HLChartAxis.accessibilityTickCount == 3)
    }
}
