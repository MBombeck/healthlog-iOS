import Foundation
@testable import HealthLog
import SwiftUI
import Testing

/// Smoke tests for the new `HLSettingsRow` / `HLSettingsIconChip` primitives.
///
/// We deliberately do not pixel-snapshot SwiftUI views (pixel-stability
/// across iOS SDK bumps is too fragile to be worth the test-failure
/// noise — same rationale the operator landed in the v0.4.0 design-system test
/// suite). Instead we test the *contract* — that the
/// three convenience initialisers compile + return a view, that the icon-
/// chip captures the geometry we promised, and that `Trailing == EmptyView`
/// vs `Trailing == HLSettingsRowValueText` vs `Trailing == <custom>` all
/// resolve to distinct types.
@MainActor
@Suite("HLSettingsRow contract")
struct HLSettingsRowTests {
    @Test("the icon chip starts at the row icon size and grows with the text up to its cap")
    func iconChipGeometry() {
        #expect(HLSettingsIconChip.baseSide == HLLayout.rowIcon)
        #expect(HLSettingsIconChip.maxSide > HLSettingsIconChip.baseSide)
        #expect(HLSettingsIconChip.side(forScaled: 10) == HLSettingsIconChip.baseSide)
        #expect(HLSettingsIconChip.side(forScaled: 40) == 40)
        #expect(HLSettingsIconChip.side(forScaled: 500) == HLSettingsIconChip.maxSide)
    }

    @Test("HLSettingsRow value-text convenience compiles + composes")
    func valueTextConvenience() {
        let row = HLSettingsRow(
            icon: "ruler",
            iconTint: HLColor.green,
            title: "Größe",
            value: "175 cm"
        )
        _ = row.body
    }

    @Test("HLSettingsRow no-trailing convenience compiles + composes")
    func emptyTrailingConvenience() {
        let row = HLSettingsRow(
            icon: "trash.fill",
            iconTint: HLColor.statusBad,
            title: "Konto löschen"
        )
        _ = row.body
    }

    @Test("HLSettingsRow generic trailing slot accepts Toggle")
    func toggleTrailing() {
        let row = HLSettingsRow(
            icon: "faceid",
            iconTint: HLColor.green,
            title: "Biometric-Lock",
            subtitle: "App nur per Face ID öffnen"
        ) {
            Toggle("", isOn: .constant(true)).labelsHidden()
        }
        _ = row.body
    }

    @Test("HLSettingsRow generic trailing slot accepts Picker")
    func pickerTrailing() {
        let row = HLSettingsRow(
            icon: "moon.fill",
            iconTint: HLAccent.primary,
            title: "Erscheinungsbild"
        ) {
            Picker("", selection: .constant("dark")) {
                Text("Dark").tag("dark")
                Text("Hell").tag("light")
            }
            .labelsHidden()
        }
        _ = row.body
    }

    // MARK: - Adaptive layout, measured differentially

    /// At an accessibility size the trailing value takes its own line; at a
    /// standard size it stays in the row. Both halves are asserted against the
    /// *same* row without a trailing value, so the claim is about where the
    /// accessory went and not about how tall large text happens to be.
    @Test("the trailing value leaves the row's line only at accessibility sizes")
    func trailingValueStacksAtAccessibilitySizes() throws {
        let plain = HLSettingsRow(icon: "ruler", title: "Größe", subtitle: "On")
        let valued = HLSettingsRow(icon: "ruler", title: "Größe", subtitle: "On", value: "175 cm")

        let plainAX = try Self.height(of: plain, size: .accessibility5)
        let valuedAX = try Self.height(of: valued, size: .accessibility5)
        #expect(valuedAX > plainAX + 20, "the value stayed on the row at accessibility5 (\(valuedAX)pt vs \(plainAX)pt)")

        let plainDefault = try Self.height(of: plain, size: .large)
        let valuedDefault = try Self.height(of: valued, size: .large)
        #expect(
            abs(valuedDefault - plainDefault) < 6,
            "the value left the row at a standard size (\(valuedDefault)pt vs \(plainDefault)pt)"
        )
        #expect(valuedDefault < 90, "a standard-size Settings row must stay compact")
    }

    /// Beside the title the symbol takes a quarter of the line at the largest
    /// sizes, and words break in two. Above it, the title wraps exactly as it
    /// does in a row without a symbol, so the row is that row plus the symbol
    /// and the gap under it.
    @Test(
        "at accessibility sizes the symbol stands above the title and takes no width from it",
        arguments: [DynamicTypeSize.accessibility1, .accessibility3, .accessibility5]
    )
    func symbolStandsAboveTheTitle(typeSize: DynamicTypeSize) throws {
        let title = Text(verbatim: "Mitteilungen aktivieren")
        let subtitle = Text(verbatim: "Für Medikamenten- und Stimmungs-Erinnerungen")
        let symbolSide: CGFloat = 30
        let bare = try DesignContractMeasure.size(
            of: HLRowLayout(title: title, subtitle: subtitle),
            typeSize: typeSize
        )
        let withSymbol = try DesignContractMeasure.markerFrame(
            in: HLRowLayout(title: title, subtitle: subtitle) {
                EmptyView()
            } leading: {
                DesignContractMeasure.marker.frame(width: symbolSide, height: symbolSide)
            },
            typeSize: typeSize
        )
        #expect(withSymbol.frame.minX == 0)
        #expect(withSymbol.frame.minY == 0, "the symbol does not stand above the title")
        #expect(withSymbol.size.height == (bare.height + symbolSide + HLSpace.xs).rounded(.up))
    }

    /// The same row at the standard sizes: the symbol stays beside the title
    /// and the row keeps the height it has without one.
    @Test(
        "at standard sizes the symbol stays beside the title and the row keeps its height",
        arguments: [DynamicTypeSize.xSmall, .large, .xxxLarge]
    )
    func symbolStaysBesideTheTitle(typeSize: DynamicTypeSize) throws {
        let title = Text(verbatim: "Konto")
        let symbolSide: CGFloat = 28
        let bare = try DesignContractMeasure.size(of: HLRowLayout(title: title), typeSize: typeSize)
        let withSymbol = try DesignContractMeasure.markerFrame(
            in: HLRowLayout(title: title) {
                EmptyView()
            } leading: {
                DesignContractMeasure.marker.frame(width: symbolSide, height: symbolSide)
            },
            typeSize: typeSize
        )
        #expect(bare.height == HLRowMetrics.minHeight)
        #expect(withSymbol.size.height == HLRowMetrics.minHeight)
        #expect(withSymbol.frame.midY == HLRowMetrics.minHeight / 2, "the symbol is not centred on the row")
    }

    /// Past the first accessibility size the indicator stops growing, so it
    /// leaves the width to the title.
    @Test("the disclosure chevron grows with the text up to the first accessibility size and no further")
    func chevronStopsGrowing() throws {
        let standard = try DesignContractMeasure.size(of: HLDisclosureChevron(), width: nil, typeSize: .large)
        let capped = try DesignContractMeasure.size(of: HLDisclosureChevron(), width: nil, typeSize: .accessibility1)
        let largest = try DesignContractMeasure.size(of: HLDisclosureChevron(), width: nil, typeSize: .accessibility5)
        #expect(HLDisclosureChevron.largestTypeSize == .accessibility1)
        #expect(capped.height > standard.height, "the chevron does not grow with the text at all")
        #expect(largest == capped, "the chevron grows past its cap")
    }

    /// The card header carries the sentence that says what the card *is*. It
    /// truncated at one line unconditionally, so enlarging the text removed
    /// words from it. Same differential: long vs short subtitle at one width.
    /// It wraps at the standard size too now (HIG: wrap, never
    /// truncate); the one-line header was what ended in "…".
    @Test("the card subtitle wraps at every text size")
    func cardSubtitleWrapsAtAccessibilitySizes() throws {
        let short: LocalizedStringKey = "Konto"
        let long: LocalizedStringKey =
            "Dein Anzeigename, deine Stammdaten und die Angaben, die auf jedem Export erscheinen."

        let shortAX = try Self.height(of: Self.card(subtitle: short), size: .accessibility5)
        let longAX = try Self.height(of: Self.card(subtitle: long), size: .accessibility5)
        #expect(longAX > shortAX + 1, "at accessibility5 the long card subtitle occupies the same \(Int(longAX))pt")

        let shortDefault = try Self.height(of: Self.card(subtitle: short), size: .large)
        let longDefault = try Self.height(of: Self.card(subtitle: long), size: .large)
        #expect(longDefault > shortDefault + 1, "at the standard size the long card subtitle was cut to one line")
        #expect(shortAX > shortDefault, "accessibility5 must already scale the card's type")
    }

    private static func card(subtitle: LocalizedStringKey) -> some View {
        HLCard("Profil", subtitle: subtitle) {
            Text("Body")
                .font(.hlBody)
        }
    }

    /// The laid-out height at a fixed width and type size — a measurement, not a
    /// bitmap (same doctrine as `HLSettingsToggleRowLayoutTests`).
    private static func height(of view: some View, width: CGFloat = 320, size: DynamicTypeSize) throws -> CGFloat {
        let renderer = ImageRenderer(
            content: view
                .frame(width: width)
                .fixedSize(horizontal: false, vertical: true)
                .dynamicTypeSize(size)
        )
        renderer.scale = 1
        let image = try #require(renderer.uiImage, "row failed to render")
        return image.size.height
    }
}
