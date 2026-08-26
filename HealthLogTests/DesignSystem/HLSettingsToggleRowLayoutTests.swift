// Diese Suite testet App-Target-Symbole, die in der SPM-Library nicht enthalten
// sind. SPM-Test-Build überspringt die Datei.
#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import SwiftUI
    import Testing

    /// **S1 (v0.15.2 felt-wave) — layout-contract test for `HLSettingsToggleRow`.**
    ///
    /// The operator b198 walkthrough bug: a long description squeezed into ~1/3 of
    /// the row width with a wide dead gap to the switch. The fix gives the text
    /// block `layoutPriority(1)` + `.fixedSize(horizontal: false, vertical: true)`
    /// so the title/Fließtext take the available width and wrap to multiple lines
    /// only when the row is genuinely narrow.
    ///
    /// Following the project's pixel-snapshot-avoidance doctrine (see
    /// `HLSkeletonSnapshotTests`), this does NOT pin rasteriser pixels. Instead it
    /// renders the primitive through `ImageRenderer` at a fixed Settings-card
    /// width and asserts the *measured height* — a degenerate "1/3 width collapse"
    /// would force the long description to wrap into many lines and balloon the
    /// height far past a correct full-width two-line layout. The correctly
    /// laid-out long-description row must therefore be only modestly taller than a
    /// title-only row, and a wrapped long-description must NOT exceed a sane
    /// ceiling. This catches a regression of the collapse without locking pixels.
    @MainActor
    @Suite("HLSettingsToggleRow layout contract")
    struct HLSettingsToggleRowLayoutTests {
        /// Renders a row at a representative Settings-card inner width and returns
        /// the laid-out height in points (nil if rendering failed).
        private func renderedHeight(
            title: LocalizedStringKey,
            description: LocalizedStringKey?,
            width: CGFloat = 320
        ) -> CGFloat? {
            let row = HLSettingsToggleRow(
                title: title,
                description: description,
                isOn: .constant(false)
            )
            .frame(width: width)
            .fixedSize(horizontal: false, vertical: true)

            let renderer = ImageRenderer(content: row)
            renderer.scale = 2
            guard let image = renderer.uiImage else { return nil }
            return image.size.height
        }

        @Test("Title-only row lays out without collapsing (renders a finite, non-zero height)")
        func titleOnlyRenders() throws {
            let height = try #require(renderedHeight(title: "Biometric lock", description: nil))
            #expect(height > 0)
            // A single-line title + switch row is short — comfortably under 80pt.
            #expect(height < 80)
        }

        @Test("Long-description row gives the Fließtext full width — not a 1/3 collapse")
        func longDescriptionDoesNotCollapse() throws {
            // The literal Forschermodus copy that triggered the operator's report.
            let longDescription: LocalizedStringKey =
                "Not a medical measurement and not therapy advice. You can turn this off anytime."
            let height = try #require(
                renderedHeight(title: "Enable research mode", description: longDescription)
            )
            #expect(height > 0)
            // With the text block at `layoutPriority(1)` + full width, this copy
            // wraps to ~2 lines beneath the title — a correct layout stays well
            // under 140pt. A 1/3-width collapse would wrap it into 5+ narrow lines
            // and blow past this ceiling, tripping the test.
            #expect(height < 140)
        }

        @Test("Description row is taller than title-only (the Fließtext actually renders beneath)")
        func descriptionAddsHeight() throws {
            let titleOnly = try #require(renderedHeight(title: "Enable research mode", description: nil))
            let withDescription = try #require(
                renderedHeight(
                    title: "Enable research mode",
                    description: "Not a medical measurement and not therapy advice. You can turn this off anytime."
                )
            )
            #expect(withDescription > titleOnly)
        }
    }

#endif
