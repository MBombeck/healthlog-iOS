@testable import HealthLog
import SwiftUI
import Testing
import UIKit

extension E2BuildingBlockTests {
    /// Contrast of a token over a surface, the token's alpha laid over it.
    private func contrast(_ ink: Color, on surface: Color, style: UIUserInterfaceStyle) -> Double {
        let traits = UITraitCollection(userInterfaceStyle: style)
        var fg = (r: CGFloat(0), g: CGFloat(0), b: CGFloat(0), a: CGFloat(0))
        var bg = (r: CGFloat(0), g: CGFloat(0), b: CGFloat(0), a: CGFloat(0))
        UIColor(ink).resolvedColor(with: traits).getRed(&fg.r, green: &fg.g, blue: &fg.b, alpha: &fg.a)
        UIColor(surface).resolvedColor(with: traits).getRed(&bg.r, green: &bg.g, blue: &bg.b, alpha: &bg.a)
        let blended = UIColor(
            red: fg.a * fg.r + (1 - fg.a) * bg.r,
            green: fg.a * fg.g + (1 - fg.a) * bg.g,
            blue: fg.a * fg.b + (1 - fg.a) * bg.b,
            alpha: 1
        )
        let base = UIColor(red: bg.r, green: bg.g, blue: bg.b, alpha: 1)
        return HLContrastClamp.contrastRatio(foreground: blended, background: base)
    }

    @Test(
        "tertiary ink keeps 3:1 on every surface, light and dark",
        arguments: [UIUserInterfaceStyle.light, .dark]
    )
    func tertiaryKeepsThreeToOne(style: UIUserInterfaceStyle) {
        for surface in [HLSurface.primary, HLSurface.secondary, HLSurface.tertiary] {
            let ratio = contrast(HLText.tertiary, on: surface, style: style)
            #expect(ratio >= 3, "tertiary on a surface at \(ratio):1")
        }
    }

    @Test("a disabled button stays readable: quiet surface for the filled one, secondary words")
    func disabledButtonReadable() throws {
        #expect(HLButtonLabel.disabledLook(for: .primary) == .quietSurface)
        #expect(HLButtonLabel.disabledLook(for: .destructive) == .quietWords)
        #expect(HLButtonLabel.disabledLook(for: .secondary) == .quietWords)
        for style in [UIUserInterfaceStyle.light, .dark] {
            #expect(contrast(HLText.secondary, on: HLSurface.tertiary, style: style) >= 3)
            #expect(contrast(HLText.secondary, on: HLSurface.primary, style: style) >= 3)
        }
        let button = HLButton(Text(verbatim: "Sichern")) {}
            .disabled(true)
            .environment(\.colorScheme, .light)
        let runs = try E2Pixels.surfaceRuns(in: button, width: 320, columns: [20], color: E2Pixels.RGB(red: 0xE9, green: 0xE6, blue: 0xE0))
        #expect((runs.first ?? 0) > 20, "the disabled filled button paints the quiet surface")
    }

    @Test("an onward symbol stands after the word, every other before it")
    func onwardSymbolTrails() {
        #expect(HLButtonLabel.iconFollowsTitle("chevron.right"))
        #expect(HLButtonLabel.iconFollowsTitle("arrow.forward"))
        #expect(!HLButtonLabel.iconFollowsTitle("checkmark"))
        #expect(!HLButtonLabel.iconFollowsTitle("plus"))
    }
}
