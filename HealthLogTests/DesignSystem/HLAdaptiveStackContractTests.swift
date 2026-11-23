@testable import HealthLog
import SwiftUI
import Testing

/// Parts that stand side by side at the standard sizes and one above the
/// other at the accessibility sizes, and the building blocks that grow with
/// the largest text instead of cutting it.
@MainActor
@Suite("Largest text: stacking instead of cutting")
struct HLAdaptiveStackContractTests {
    private static func pair() -> some View {
        HLAdaptiveStack(spacing: 10) { _ in
            Color.clear.frame(width: 100, height: 20)
            DesignContractMeasure.marker.frame(width: 100, height: 20)
        }
    }

    @Test("below the accessibility sizes the parts stand side by side, as in an HStack")
    func sideBySideAtStandardSizes() throws {
        for typeSize in [DynamicTypeSize.large, .xxxLarge] {
            #expect(!HLAdaptiveStack<EmptyView>.isStacked(at: typeSize))
            let second = try DesignContractMeasure.markerFrame(in: Self.pair(), typeSize: typeSize)
            #expect(second.size.height == 20, "the parts did not stay on one line")
            #expect(second.frame.minY == 0)
            #expect(second.frame.width == 100)

            let plain = try DesignContractMeasure.markerFrame(in: HStack(spacing: 10) {
                Color.clear.frame(width: 100, height: 20)
                DesignContractMeasure.marker.frame(width: 100, height: 20)
            }, typeSize: typeSize)
            #expect(second.frame == plain.frame, "the standard sizes must look exactly like an HStack")
        }
    }

    @Test(
        "from the first accessibility size the parts stand one above the other, flush left",
        arguments: [DynamicTypeSize.accessibility1, .accessibility5]
    )
    func stackedAtAccessibilitySizes(typeSize: DynamicTypeSize) throws {
        #expect(HLAdaptiveStack<EmptyView>.isStacked(at: typeSize))
        let second = try DesignContractMeasure.markerFrame(in: Self.pair(), typeSize: typeSize)
        #expect(second.frame.minX == 0, "the second part does not start at the leading edge")
        #expect(second.frame.minY == 20 + HLAdaptiveStack<EmptyView>.stackedSpacing)
        #expect(second.size.height == 2 * 20 + HLAdaptiveStack<EmptyView>.stackedSpacing)
    }

    @Test("a button title that has to wrap makes the button taller instead of being cut")
    func wrappedButtonTitleGrowsTheButton() throws {
        let oneLine = try DesignContractMeasure.size(
            of: HLButton(verbatim: "OK", variant: .secondary) {},
            typeSize: .accessibility5,
            language: "de"
        )
        let wrapped = try DesignContractMeasure.size(
            of: HLButton(verbatim: "Alles auswählen", variant: .secondary) {},
            typeSize: .accessibility5,
            language: "de"
        )
        // Two lines of text and more: the button holds both of them.
        #expect(wrapped.height >= 2 * (oneLine.height - HLSpace.lg))
        #expect(wrapped.height > oneLine.height)

        // At the standard size a title that fits keeps the one button height.
        let standard = try DesignContractMeasure.size(
            of: HLButton(verbatim: "Alles auswählen", variant: .secondary) {},
            language: "de"
        )
        #expect(standard.height == HLLayout.buttonHeight)
    }

    @Test(
        "in a card at the largest sizes a wrapped title is never cut by the button",
        arguments: [DynamicTypeSize.accessibility3, .accessibility5]
    )
    func wrappedButtonTitleInACard(typeSize: DynamicTypeSize) throws {
        for width in stride(from: CGFloat(300), through: 420, by: 20) {
            let button = try DesignContractMeasure.size(
                of: HLButton(verbatim: "Alles auswählen", variant: .secondary) {},
                width: width,
                typeSize: typeSize,
                language: "de"
            )
            let words = try DesignContractMeasure.size(
                of: Text(verbatim: "Alles auswählen").font(.hlHeadline).multilineTextAlignment(.center),
                width: width - 2 * HLSpace.lg,
                typeSize: typeSize,
                language: "de"
            )
            #expect(
                button.height >= HLButton.titleMinimumScale * words.height,
                "at \(width) pt the button is lower than its title"
            )
        }
    }

    @Test("at the largest sizes the banner's retry button stands on its own line and keeps a hit target")
    func errorBannerRetryStacks() throws {
        let withRetry = try DesignContractMeasure.size(
            of: ErrorBanner(error: .offline, retry: {}),
            typeSize: .accessibility5,
            language: "de"
        )
        let without = try DesignContractMeasure.size(
            of: ErrorBanner(error: .offline),
            typeSize: .accessibility5,
            language: "de"
        )
        #expect(withRetry.height >= without.height + HLHitTarget.minimum)
    }

    @Test("the floating period control is a menu from the first accessibility size on")
    func periodControlTurnsIntoAMenu() {
        typealias Control = HLFloatingPeriodControl<MoodPeriod>
        #expect(!Control.usesMenu(at: .large))
        #expect(!Control.usesMenu(at: .xxxLarge))
        #expect(Control.usesMenu(at: .accessibility1))
        #expect(Control.usesMenu(at: .accessibility5))
    }
}
