@testable import HealthLog
import SwiftUI
import Testing

/// Several buttons of equal rank in one row, the small form that row can
/// take, and the forms beside the standard button: a run-time title, a push,
/// the bare label, the link that pushes, the row of chips.
@MainActor
@Suite("Button row: equal shares, a small form of 44 pt")
struct HLButtonRowContractTests {
    private static let width: CGFloat = 320

    private static func row(_ titles: [String], size: HLButtonRowSize = .regular) -> some View {
        HLButtonRow(size: size) {
            ForEach(titles, id: \.self) { title in
                HLButton(Text(verbatim: title), variant: .secondary) {}
            }
        }
    }

    @Test("three buttons of a row are equally wide and stand in the order they are written", arguments: [0, 1, 2])
    func threeShareTheWidth(place: Int) throws {
        let third = (Self.width - 2 * HLLayout.buttonGap) / 3
        let found = try DesignContractMeasure.markerFrame(in: HLButtonRow {
            ForEach(0 ..< 3, id: \.self) { index in
                if index == place {
                    DesignContractMeasure.marker.frame(height: 20)
                } else {
                    Color.clear.frame(height: 20)
                }
            }
        }, width: Self.width)
        // The marker is found on whole pixels, a third of the row is not one.
        #expect(abs(found.frame.width - third) <= 1)
        #expect(abs(found.frame.minX - CGFloat(place) * (third + HLLayout.buttonGap)) <= 1)
        #expect(found.size.height == 20, "three short elements did not stay on one line")
    }

    @Test("two buttons of a row are as wide as the two of a pair")
    func twoShareTheWidth() throws {
        let half = (Self.width - HLLayout.buttonGap) / 2
        let found = try DesignContractMeasure.markerFrame(in: HLButtonRow {
            Color.clear.frame(height: 20)
            DesignContractMeasure.marker.frame(height: 20)
        }, width: Self.width)
        #expect(found.frame.width == half)
        #expect(found.frame.maxX == Self.width)
    }

    @Test("the small form is as high as the hit target, never lower, and the regular one as high as every button")
    func smallFormKeepsTheHitTarget() throws {
        let titles = ["250", "500", "750"]
        let small = try DesignContractMeasure.size(of: Self.row(titles, size: .small), width: Self.width)
        #expect(small.height == HLHitTarget.minimum)
        #expect(small.height >= 44)

        let regular = try DesignContractMeasure.size(of: Self.row(titles), width: Self.width)
        #expect(regular.height == HLLayout.buttonHeight)

        // Larger text may make the small form higher, never lower.
        for typeSize in [DynamicTypeSize.xSmall, .xxxLarge] {
            let scaled = try DesignContractMeasure.size(
                of: Self.row(titles, size: .small),
                width: Self.width,
                typeSize: typeSize
            )
            #expect(scaled.height >= HLHitTarget.minimum, "the small form fell under 44 pt at \(typeSize)")
        }
    }

    @Test("the small form belongs to the row: a button outside one keeps its height")
    func smallFormStaysInsideTheRow() throws {
        let alone = try DesignContractMeasure.size(of: HLButton(Text(verbatim: "+250 ml"), variant: .secondary) {})
        #expect(alone.height == HLLayout.buttonHeight)
    }

    @Test(
        "from the first accessibility size the buttons of a row stand one above the other",
        arguments: [DynamicTypeSize.accessibility1, .accessibility5]
    )
    func rowStacksAtAccessibilitySizes(typeSize: DynamicTypeSize) throws {
        let found = try DesignContractMeasure.markerFrame(
            in: HLButtonRow {
                DesignContractMeasure.marker.frame(height: 20)
                Color.clear.frame(height: 20)
                Color.clear.frame(height: 20)
            },
            width: Self.width,
            typeSize: typeSize
        )
        #expect(found.frame.width == Self.width)
        #expect(found.frame.minY == 0, "the first button does not stand first")
        #expect(found.size.height == 3 * 20 + 2 * HLLayout.buttonGap)
    }

    @Test("a title too long for its share stacks the row instead of shrinking")
    func rowStacksForALongTitle() throws {
        let titles = ["Blutdruck", "Herzfrequenzvariabilität", "Gewicht"]
        let stacked = try DesignContractMeasure.size(of: Self.row(titles, size: .small), width: Self.width)
        #expect(stacked.height == 3 * HLHitTarget.minimum + 2 * HLLayout.buttonGap)
    }

    // MARK: - Forms beside the standard button

    @Test("a run-time title draws the button a catalog key draws")
    func runtimeTitle() throws {
        let key = try DesignContractMeasure.size(of: HLButton("Save", systemImage: "checkmark") {}, width: nil)
        let text = try DesignContractMeasure.size(
            of: HLButton(Text(verbatim: "Save"), systemImage: "checkmark") {},
            width: nil
        )
        #expect(key == text)
        #expect(!HLButton(Text(verbatim: "Save")) {}.pushesDestination)
    }

    @Test("the standard button as a push is a link to its destination, in both title forms")
    func pushForms() throws {
        let key = HLButton(HLControlWord.edit.key, systemImage: "pencil", variant: .secondary, destination: { Color.clear })
        let text = HLButton(Text(verbatim: "Lisinopril"), variant: .secondary, destination: { Color.clear })
        #expect(key.pushesDestination)
        #expect(text.pushesDestination)

        let acting = HLButton(HLControlWord.edit.key, systemImage: "pencil", variant: .secondary) {}
        #expect(!acting.pushesDestination)
        let pushedSize = try DesignContractMeasure.size(of: key, width: Self.width)
        let actingSize = try DesignContractMeasure.size(of: acting, width: Self.width)
        #expect(pushedSize == actingSize)
    }

    @Test(
        "the bare label is what the button draws, at every text size",
        arguments: [DynamicTypeSize.large, .accessibility5]
    )
    func labelMatchesTheButton(typeSize: DynamicTypeSize) throws {
        let button = try DesignContractMeasure.size(
            of: HLButton("Share", systemImage: "square.and.arrow.up", variant: .secondary) {},
            width: Self.width,
            typeSize: typeSize
        )
        let label = try DesignContractMeasure.size(
            of: HLButtonLabel("Share", systemImage: "square.and.arrow.up", variant: .secondary),
            width: Self.width,
            typeSize: typeSize
        )
        #expect(label == button)
        let runtime = try DesignContractMeasure.size(
            of: HLButtonLabel(Text(verbatim: "Share"), systemImage: "square.and.arrow.up", variant: .secondary),
            width: Self.width,
            typeSize: typeSize
        )
        #expect(runtime == button)
    }

    @Test("a text link that pushes keeps the tap area of the one that acts")
    func linkPush() throws {
        let acting = HLLinkButton("Show all") {}
        let pushing = HLLinkButton("Show all", destination: { Color.clear })
        #expect(!acting.pushesDestination)
        #expect(pushing.pushesDestination)

        let actingSize = try DesignContractMeasure.size(of: acting, width: Self.width)
        let pushingSize = try DesignContractMeasure.size(of: pushing, width: Self.width)
        #expect(actingSize.height == HLLinkButton.hitHeight)
        #expect(pushingSize == actingSize)
    }

    // MARK: - Chips that share a line

    @Test("seven chips of a row are equally wide", arguments: [0, 3, 6])
    func chipsShareTheWidth(place: Int) throws {
        // A width at which a seventh is a whole number of points.
        let width = 7 * 44 + 6 * HLChipRow<EmptyView>.gap
        let found = try DesignContractMeasure.markerFrame(in: HLChipRow {
            ForEach(0 ..< 7, id: \.self) { index in
                if index == place {
                    DesignContractMeasure.marker.frame(height: 20)
                } else {
                    Color.clear.frame(height: 20)
                }
            }
        }, width: width)
        #expect(found.frame.width == 44)
        #expect(found.frame.minX == CGFloat(place) * (44 + HLChipRow<EmptyView>.gap))
    }

    @Test("a chip of a row fills its share instead of keeping the width of its word")
    func chipFillsItsShare() throws {
        let width = 7 * 44 + 6 * HLChipRow<EmptyView>.gap
        let found = try DesignContractMeasure.markerFrame(in: HLChipRow {
            HLChip(verbatim: "Mo", isSelected: false) {}
                .overlay { DesignContractMeasure.marker }
            ForEach(0 ..< 6, id: \.self) { _ in
                HLChip(verbatim: "Di", isSelected: false) {}
            }
        }, width: width)
        #expect(found.frame.width == 44)
        #expect(found.frame.height == HLChip.visibleHeight)
    }

    @Test("the chips of a row stand on one line, and flow onto more once they no longer fit on it")
    func chipRowFlows() throws {
        let days = ["Mo", "Di", "Mi", "Do", "Fr", "Sa", "So"]
        let row = HLChipRow {
            ForEach(days, id: \.self) { day in
                HLChip(verbatim: day, isSelected: day == "Mi") {}
            }
        }
        let oneLine = try DesignContractMeasure.size(of: row, width: Self.width)
        #expect(oneLine.height == HLChip.visibleHeight)

        let largest = try DesignContractMeasure.size(of: row, width: Self.width, typeSize: .accessibility5)
        let oneChip = try DesignContractMeasure.size(
            of: HLChip(verbatim: "Mo", isSelected: false) {},
            width: nil,
            typeSize: .accessibility5
        )
        #expect(largest.height > oneChip.height, "seven chips at the largest size were pressed onto one line")
    }

    @Test("a chip takes a spoken title for an abbreviation without changing what it draws")
    func chipSpokenTitle() throws {
        let plain = try DesignContractMeasure.size(of: HLChip("Mo", isSelected: true) {}, width: nil)
        let spoken = try DesignContractMeasure.size(
            of: HLChip("Mo", spokenTitle: "Monday", isSelected: true) {},
            width: nil
        )
        #expect(plain == spoken)
    }
}
