@testable import HealthLog
import SwiftUI
import Testing

/// The button family: three variants a screen chooses from, one height, and
/// the two quiet forms beside it (text link, icon button).
@MainActor
@Suite("Buttons: three variants, one height")
struct HLButtonContractTests {
    @Test("a screen chooses from three variants, and each draws its own surface")
    func threeVariants() throws {
        #expect(HLButton.Variant.standard.count == 3)
        #expect(Set(HLButton.Variant.standard).isDisjoint(with: HLButton.Variant.retired))
        #expect(
            Set(HLButton.Variant.allCases) == Set(HLButton.Variant.standard + HLButton.Variant.retired),
            "a variant exists that is neither standard nor retired"
        )

        // What tells them apart on the screen: the primary one is filled with
        // the ink, the other two are not filled, and the destructive one has
        // red words where the secondary one has the ink.
        let primary = try Self.fill(of: HLButton("Save", variant: .primary) {})
        let secondary = try Self.fill(of: HLButton("Save", variant: .secondary) {})
        let destructive = try Self.fill(of: HLButton("Save", variant: .destructive) {})
        #expect(primary.alpha > 0.99)
        #expect(secondary.alpha < 0.01, "the secondary button has a fill")
        #expect(destructive.alpha < 0.01, "the destructive button has a fill")

        let secondaryInk = try Self.ink(of: HLButton("Save", variant: .secondary) {})
        let destructiveInk = try Self.ink(of: HLButton("Save", variant: .destructive) {})
        #expect(Self.isRed(destructiveInk), "the words of the destructive button are not red")
        #expect(!Self.isRed(secondaryInk), "the words of the secondary button are red")
    }

    @Test("a destructive button with a symbol and a running one are no red surface either")
    func destructiveStaysCalm() throws {
        let withSymbol = try Self.fill(
            of: HLButton(HLControlWord.delete.key, systemImage: "trash", variant: .destructive) {}
        )
        #expect(withSymbol.alpha < 0.01)
        let running = try Self.fill(of: HLButton("Save", variant: .destructive, isLoading: true) {})
        #expect(running.alpha < 0.01)
    }

    @Test("the delete button has no red surface, and on a page it is the destructive variant")
    func deleteButtonIsCalm() throws {
        let page = try Self.fill(of: HLDeleteButton(form: .page, action: .undoable {}))
        #expect(page.alpha < 0.01, "the delete button on a page is filled")
        let row = try Self.fill(of: HLDeleteButton(form: .row, action: .undoable {}))
        #expect(row.alpha < 0.01, "the delete row is filled")

        // One drawing for one thing: the same pixels, whichever name is called.
        let viaDelete = try Self.middleRow(of: HLDeleteButton(form: .page, action: .undoable {}))
        let viaVariant = try Self.middleRow(of: HLButton(HLControlWord.delete.key, variant: .destructive) {})
        #expect(viaDelete == viaVariant, "the delete button on a page and the destructive variant differ")
        #expect(try Self.isRed(Self.ink(of: HLDeleteButton(form: .page, action: .undoable {}))))

        let size = try DesignContractMeasure.size(of: HLDeleteButton(form: .page, action: .undoable {}))
        #expect(size.height == HLLayout.buttonHeight)
        let rowSize = try DesignContractMeasure.size(of: HLDeleteButton(form: .row, action: .undoable {}))
        #expect(rowSize.height == HLLayout.rowMinHeight)
    }

    @Test(
        "a running button is as wide as a resting one",
        arguments: [HLButton.Variant.primary, .destructive]
    )
    func loadingKeepsWidth(variant: HLButton.Variant) throws {
        let resting = try Self.paintedWidth(of: HLButton("control.save", variant: variant) {})
        let running = try Self.paintedWidth(of: HLButton("control.save", variant: variant, isLoading: true) {})
        #expect(resting == 320)
        #expect(running == resting, "the running button is drawn narrower")
    }

    @Test(
        "at the largest type a German word on a button with a symbol stays in one piece",
        arguments: [CGFloat(320), 370]
    )
    func noBrokenWord(width: CGFloat) throws {
        let oneLine = try DesignContractMeasure.size(
            of: HLButton("OK", variant: .secondary) {},
            width: width,
            typeSize: .accessibility5,
            language: "de"
        )
        let add = try DesignContractMeasure.size(
            of: HLButton(HLControlWord.add.key, systemImage: "plus", variant: .secondary) {},
            width: width,
            typeSize: .accessibility5,
            language: "de"
        )
        #expect(add.height == oneLine.height, "„Hinzufügen“ takes a second line, so the word was cut")
        #expect(add.width == width)
    }

    @Test("a title of several words may wrap at the largest type, a short one never does")
    func wrapping() throws {
        let short = try DesignContractMeasure.size(
            of: HLButton("Save", systemImage: "checkmark") {},
            typeSize: .accessibility5
        )
        let long = try DesignContractMeasure.size(
            of: HLButton(verbatim: "Add another medication", icon: "plus", variant: .primary) {},
            typeSize: .accessibility5
        )
        #expect(long.height > short.height)
        #expect(long.width == 320)
    }

    @Test(
        "every variant has the layout's height, and onboarding its larger one",
        arguments: HLButton.Variant.standard
    )
    func height(variant: HLButton.Variant) throws {
        #expect(HLButton.height(variant: variant) == HLLayout.buttonHeight)
        #expect(HLButton.height(variant: variant, onboarding: true) == HLLayout.onboardingButtonHeight)

        let regular = try DesignContractMeasure.size(of: HLButton("Save", variant: variant) {})
        #expect(regular.height == HLLayout.buttonHeight)
        #expect(regular.width == 320, "a button takes the full width")

        let withSymbol = try DesignContractMeasure.size(
            of: HLButton("Save", systemImage: "checkmark", variant: variant) {}
        )
        #expect(withSymbol.height == HLLayout.buttonHeight)

        let onboarding = try DesignContractMeasure.size(
            of: HLButton("Save", variant: variant) {}.hlOnboardingSize()
        )
        #expect(onboarding.height == HLLayout.onboardingButtonHeight)
    }

    @Test("a retired restrained button cannot grow back into a slab")
    func restrainedStaysAtFloor() {
        #expect(HLButton.height(variant: .restrained, size: .large, onboarding: true) == HLHitTarget.minimum)
    }

    @Test("a text link is one line with a full tap target")
    func linkButton() throws {
        #expect(HLLinkButton.hitHeight == HLHitTarget.minimum)
        let plain = try DesignContractMeasure.size(of: HLLinkButton("Advanced") {})
        #expect(plain.height == HLLinkButton.hitHeight)
        #expect(plain.width == 320)

        let unfolding = try DesignContractMeasure.size(of: HLLinkButton("Advanced", isExpanded: false) {})
        #expect(unfolding.height == plain.height)
    }

    @Test("an icon button is a square tap target in both styles", arguments: [HLIconButtonStyle.plain, .bar])
    func iconButton(style: HLIconButtonStyle) throws {
        let button = HLIconButton(systemImage: "plus", label: "Add entry", style: style) {}
        let standard = try DesignContractMeasure.size(of: button, width: nil)
        #expect(standard == CGSize(width: HLLayout.iconButton, height: HLLayout.iconButton))

        let largest = try DesignContractMeasure.size(of: button, width: nil, typeSize: .accessibility5)
        #expect(largest.width > standard.width)
        #expect(largest.width <= HLIconButton.maxSide)
        #expect(largest.width == largest.height)
    }

    @Test("an icon button never falls under the tap target and stops growing at its cap")
    func iconButtonSide() {
        #expect(HLIconButton.baseSide == HLLayout.iconButton)
        #expect(HLIconButton.side(forScaled: 10) == HLLayout.iconButton)
        #expect(HLIconButton.side(forScaled: 50) == 50)
        #expect(HLIconButton.side(forScaled: 500) == HLIconButton.maxSide)
    }

    @Test("a chosen icon button is dark like a chosen chip, and filled in both styles")
    func iconButtonSelected() throws {
        typealias Look = HLIconButton.Appearance
        #expect(HLIconButton.appearance(style: .plain, isSelected: false)
            == Look(surface: .none, ink: .resting, filledSymbol: false))
        #expect(HLIconButton.appearance(style: .plain, isSelected: true)
            == Look(surface: .none, ink: .full, filledSymbol: true))
        #expect(HLIconButton.appearance(style: .bar, isSelected: false)
            == Look(surface: .glass, ink: .resting, filledSymbol: false))
        #expect(HLIconButton.appearance(style: .bar, isSelected: true)
            == Look(surface: .selected, ink: .onSelectedSurface, filledSymbol: true))

        // In a bar the chosen button carries the surface of the chosen chip.
        let ink = HLText.primary
        let chip = try Self.middleRow(of: HLChip(verbatim: "Week", isSelected: true) {}.tint(ink))
        let chipFill = try Self.surface(in: chip)
        let bar = try Self.middleRow(
            of: HLIconButton(systemImage: "star", label: "Pinned", style: .bar, isSelected: true) {}.tint(ink)
        )
        let barFill = try Self.surface(in: bar)
        #expect(
            Self.isSame(barFill, chipFill),
            "the chosen icon button \(barFill) and the chosen chip \(chipFill) differ"
        )
        #expect(bar.count(where: { $0.alpha > 0.5 }) == Int(HLLayout.iconButton), "the circle is not the tap target")

        // In the content there is no surface: the symbol shows the state.
        let off = try Self.middleRow(of: HLIconButton(systemImage: "star", label: "Pinned") {})
        let on = try Self.middleRow(of: HLIconButton(systemImage: "star", label: "Pinned", isSelected: true) {})
        #expect(on.count(where: { $0.alpha > 0.5 }) < Int(HLLayout.iconButton), "the plain button has a surface")
        #expect(
            on.count(where: { $0.alpha > 0.5 }) > off.count(where: { $0.alpha > 0.5 }),
            "the chosen symbol is not filled"
        )
    }

    @Test(
        "a chosen icon button is as large as one at rest, with an action and with a menu",
        arguments: [HLIconButtonStyle.plain, .bar]
    )
    func iconButtonSelectedKeepsSize(style: HLIconButtonStyle) throws {
        let side = CGSize(width: HLLayout.iconButton, height: HLLayout.iconButton)
        let action = HLIconButton(systemImage: "star", label: "Pinned", style: style, isSelected: true) {}
        #expect(try DesignContractMeasure.size(of: action, width: nil) == side)
        let menu = HLIconButton(systemImage: "star", label: "Pinned", style: style, isSelected: true, menu: {
            Button("Edit") {}
        })
        #expect(try DesignContractMeasure.size(of: menu, width: nil) == side)
    }

    // MARK: - Reading the drawn button

    private struct Pixel: Equatable {
        let red: Double
        let green: Double
        let blue: Double
        let alpha: Double
    }

    /// One row of pixels through the middle of the view, drawn 320 pt wide at
    /// scale 1 on a clear ground.
    private static func middleRow(of view: some View) throws -> [Pixel] {
        let renderer = ImageRenderer(content: view.frame(width: 320).fixedSize(horizontal: false, vertical: true))
        renderer.scale = 1
        renderer.isOpaque = false
        let image = try #require(renderer.cgImage, "the view did not render")
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let row = height / 2
        return (0 ..< width).map { column in
            let offset = (row * width + column) * 4
            let alpha = Double(bytes[offset + 3]) / 255
            let scale = alpha > 0 ? 1 / (255 * alpha) : 0
            return Pixel(
                red: Double(bytes[offset]) * scale,
                green: Double(bytes[offset + 1]) * scale,
                blue: Double(bytes[offset + 2]) * scale,
                alpha: alpha
            )
        }
    }

    /// The colour of the surface, read at half height a few points in from
    /// the trailing edge: clear of the outline and of every label.
    private static func fill(of view: some View) throws -> Pixel {
        let row = try middleRow(of: view)
        return try #require(row.dropLast(6).last)
    }

    /// The colour of the label: the most opaque pixel at half height, away
    /// from the outline at both ends.
    private static func ink(of view: some View) throws -> Pixel {
        let row = try middleRow(of: view)
        return try #require(row.dropFirst(6).dropLast(6).max { $0.alpha < $1.alpha })
    }

    /// The colour of a filled shape in a row: a few points in from its
    /// leading edge, clear of the edge's blend and of the label.
    private static func surface(in row: [Pixel]) throws -> Pixel {
        let edge = try #require(row.firstIndex { $0.alpha > 0.5 })
        return try #require(row.indices.contains(edge + 4) ? row[edge + 4] : nil)
    }

    private static func isSame(_ one: Pixel, _ other: Pixel) -> Bool {
        let step = 2.0 / 255
        return abs(one.red - other.red) <= step && abs(one.green - other.green) <= step
            && abs(one.blue - other.blue) <= step && abs(one.alpha - other.alpha) <= step
    }

    private static func isRed(_ pixel: Pixel) -> Bool {
        pixel.alpha > 0.5 && pixel.red > pixel.green * 1.5 && pixel.red > pixel.blue * 1.2
    }

    /// From the first to the last pixel that is not clear. The hairline of a
    /// button without a fill counts: it is faint, not absent.
    private static func paintedWidth(of view: some View) throws -> Int {
        let row = try middleRow(of: view)
        let first = try #require(row.firstIndex { $0.alpha > 0.02 })
        let last = try #require(row.lastIndex { $0.alpha > 0.02 })
        return last - first + 1
    }
}
