@testable import HealthLog
import SwiftUI
import Testing

/// Two buttons side by side: equally wide while both labels have room, one
/// above the other as soon as they do not.
extension HLButtonContractTests {
    private static func pair(primary: String, secondary: String = "Abbrechen") -> some View {
        HLButtonPair {
            HLButton(verbatim: primary, variant: .primary) {}
        } secondary: {
            HLButton(verbatim: secondary, variant: .secondary) {}
        }
    }

    private static func single(_ title: String, typeSize: DynamicTypeSize) throws -> CGSize {
        try DesignContractMeasure.size(
            of: HLButton(verbatim: title, variant: .primary) {},
            typeSize: typeSize,
            language: "de"
        )
    }

    @Test("side by side the two buttons of a pair are equally wide, the main action trailing")
    func pairSharesTheWidth() throws {
        #expect(HLButtonPair<EmptyView, EmptyView>.gap == HLLayout.buttonGap)
        let half = (320 - HLLayout.buttonGap) / 2

        let main = try DesignContractMeasure.markerFrame(in: HLButtonPair {
            DesignContractMeasure.marker.frame(height: 20)
        } secondary: {
            Color.clear.frame(height: 20)
        })
        #expect(main.frame.width == half)
        #expect(main.frame.maxX == 320, "the main action does not stand at the trailing edge")
        #expect(main.size.height == 20)

        let other = try DesignContractMeasure.markerFrame(in: HLButtonPair {
            Color.clear.frame(height: 20)
        } secondary: {
            DesignContractMeasure.marker.frame(height: 20)
        })
        #expect(other.frame.width == half)
        #expect(other.frame.minX == 0)

        let buttons = try DesignContractMeasure.size(of: Self.pair(primary: "Sichern"), language: "de")
        #expect(buttons.height == HLLayout.buttonHeight, "two short titles did not stay on one line")
        #expect(buttons.width == 320)
    }

    @Test(
        "from the first accessibility size a pair is stacked, main action first, and no word is cut",
        arguments: [DynamicTypeSize.accessibility1, .accessibility5]
    )
    func pairStacksAtAccessibilitySizes(typeSize: DynamicTypeSize) throws {
        let main = try DesignContractMeasure.markerFrame(
            in: HLButtonPair {
                DesignContractMeasure.marker.frame(height: 20)
            } secondary: {
                Color.clear.frame(height: 20)
            },
            typeSize: typeSize
        )
        #expect(main.frame.width == 320)
        #expect(main.frame.minY == 0, "the main action does not stand first")
        #expect(main.size.height == 2 * 20 + HLLayout.buttonGap)

        // Stacked, each button has the full width: both German words stay on
        // one line, so the pair is as high as two one-line buttons.
        let oneLine = try Self.single("OK", typeSize: typeSize)
        let pair = try DesignContractMeasure.size(
            of: Self.pair(primary: "Hinzufügen"),
            typeSize: typeSize,
            language: "de"
        )
        #expect(pair.height == 2 * oneLine.height + HLLayout.buttonGap, "a word of the pair was cut or shrunk")
    }

    @Test("a long title stacks the pair at the standard size instead of shrinking")
    func pairStacksForALongTitle() throws {
        let long = "Verbindung trennen und Daten löschen"
        // Alone on the full width the title has room on one line.
        #expect(try Self.single(long, typeSize: .large).height == HLLayout.buttonHeight)

        let pair = try DesignContractMeasure.size(of: Self.pair(primary: long), language: "de")
        #expect(pair.height == 2 * HLLayout.buttonHeight + HLLayout.buttonGap)

        // The same from the other side: a long second action stacks as well.
        let other = try DesignContractMeasure.size(
            of: Self.pair(primary: "Sichern", secondary: long),
            language: "de"
        )
        #expect(other.height == pair.height)

        // Wide enough for both, the pair goes back on one line.
        let wide = try DesignContractMeasure.size(of: Self.pair(primary: long), width: 720, language: "de")
        #expect(wide.height == HLLayout.buttonHeight)
    }
}
