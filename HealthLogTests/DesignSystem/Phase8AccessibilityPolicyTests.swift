// Renders app-target design-system symbols that the SPM library does not
// contain; the SPM test build skips the file (repo convention).
#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import SwiftUI
    import Testing

    /// Settings rows must keep saying more as the type grows: a hint that
    /// truncates at accessibility sizes makes the text bigger and the
    /// information smaller.
    ///
    /// Measured differentially rather than by bitmap: a long subtitle and a
    /// short one, rendered at the same width and the same type size. A row that
    /// wraps is taller for the long one; a row that truncates is exactly as tall
    /// for both.
    @MainActor
    @Suite("Phase 08 accessibility policy")
    struct Phase8AccessibilityPolicyTests {
        @Test("Settings rows wrap their hint at accessibility sizes and keep one hint line below them")
        func settingsRowsWrapAtAccessibilitySizes() throws {
            var violations: [String] = []

            let shortHint: LocalizedStringKey = "On"
            let longHint: LocalizedStringKey =
                "Sync every measurement with the paired server whenever the app returns to the foreground."

            let shortAX = try Self.height(of: Self.settingsRow(subtitle: shortHint), size: .accessibility5)
            let longAX = try Self.height(of: Self.settingsRow(subtitle: longHint), size: .accessibility5)
            let shortDefault = try Self.height(of: Self.settingsRow(subtitle: shortHint), size: .large)
            let longDefault = try Self.height(of: Self.settingsRow(subtitle: longHint), size: .large)

            if longAX <= shortAX + 1 {
                violations.append(
                    "at accessibility5 the long hint occupies the same \(Int(longAX))pt as the short one"
                )
            }

            // At the standard sizes the hint may take a second line (1.7: a
            // cut hint read as broken), never a third; the row stays compact.
            // Only the accessibility sizes let it wrap further.
            #expect(longDefault > shortDefault, "a long hint should take its second line at the standard size")
            #expect(longDefault <= shortDefault + 24, "a long hint took more than one extra line at the standard size")
            #expect(longDefault < 90, "a standard-size Settings row must stay compact")
            #expect(shortAX > shortDefault, "accessibility5 must already scale the row's type")
            #expect(violations.isEmpty, "accessibility Settings row did not wrap")
        }

        // MARK: - Rendering

        private static func settingsRow(subtitle: LocalizedStringKey) -> some View {
            HLSettingsRow(icon: "arrow.triangle.2.circlepath", title: "Sync", subtitle: subtitle)
        }

        /// The laid-out height of a view at a fixed width and type size. A
        /// measurement, not a bitmap — the value that changes when a layout
        /// reflows and stays put when it truncates.
        private static func height(
            of view: some View,
            width: CGFloat = 320,
            size: DynamicTypeSize
        ) throws -> CGFloat {
            let renderer = ImageRenderer(
                content: view
                    .frame(width: width)
                    .fixedSize(horizontal: false, vertical: true)
                    .dynamicTypeSize(size)
            )
            renderer.scale = 1
            guard let image = renderer.uiImage else {
                throw Phase8PolicyFailure.renderFailed
            }
            return image.size.height
        }
    }

    private enum Phase8PolicyFailure: Error {
        case renderFailed
    }
#endif
