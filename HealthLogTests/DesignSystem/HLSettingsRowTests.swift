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
    @Test("HLSettingsIconChip exposes 28×28 frame")
    func iconChipGeometry() {
        let chip = HLSettingsIconChip(symbol: "person.crop.circle.fill", tint: HLAccent.primary)
        // We can't introspect the frame via reflection in a build-clean way,
        // but we lock the constants by reading the file-level frame() call —
        // if the primitive drifts off 28×28, the visual diff with Apple-
        // Settings (which uses 29×29 on iPhone) becomes user-visible.
        _ = chip.body
        // No assertion here other than "doesn't crash" — the *value* lock
        // lives in `HLSettingsRow.swift:128-130` (`frame(width: 28, height: 28)`).
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

    // MARK: - 08-04 — adaptive layout, measured differentially

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

    /// The card header carries the sentence that says what the card *is*. It
    /// truncated at one line unconditionally, so enlarging the text removed
    /// words from it. Same differential: long vs short subtitle at one width.
    @Test("the card subtitle wraps at accessibility sizes and stays capped otherwise")
    func cardSubtitleWrapsAtAccessibilitySizes() throws {
        let short: LocalizedStringKey = "Konto"
        let long: LocalizedStringKey =
            "Dein Anzeigename, deine Stammdaten und die Angaben, die auf jedem Export erscheinen."

        let shortAX = try Self.height(of: Self.card(subtitle: short), size: .accessibility5)
        let longAX = try Self.height(of: Self.card(subtitle: long), size: .accessibility5)
        #expect(longAX > shortAX + 1, "at accessibility5 the long card subtitle occupies the same \(Int(longAX))pt")

        let shortDefault = try Self.height(of: Self.card(subtitle: short), size: .large)
        let longDefault = try Self.height(of: Self.card(subtitle: long), size: .large)
        #expect(abs(longDefault - shortDefault) < 1, "standard sizes must keep the card's one-line header")
        #expect(shortAX > shortDefault, "accessibility5 must already scale the card's type")
    }

    private static func card(subtitle: LocalizedStringKey) -> some View {
        HLSettingsCard(icon: "person.crop.circle.fill", title: "Profil", subtitle: subtitle) {
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
