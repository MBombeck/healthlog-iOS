import Foundation
@testable import HealthLog
import SwiftUI
import Testing

/// v0.6.1.10 Y9-F — regression lock for the ON-track contrast fix that
/// closes the REG-13 invisible-switch pattern reborn after v0.6.1.7's
/// root-tint pin. The ON-track stays sourced from `HLText.secondary`
/// regardless of the `.tint` cascade — a future wave that re-routes the
/// track back through the App-root `.tint(HLText.primary)` would re-introduce
/// the near-white-thumb-on-near-white-track collapse in Dark mode.
///
/// **QoL-A2 (2026-06-02):** `HLToggleStyle` now wraps the **native** switch
/// (`.toggleStyle(.switch)`) and pins its contrast via `.tint(HLText.secondary)`
/// instead of a hand-rolled Capsule. The mono-secondary contract is unchanged;
/// the source assertion now locks the native tint-pin rather than the old
/// hand-rolled `AnyShapeStyle` fill.
@Suite("HLToggleStyle Y9 ON-track contrast")
struct HLToggleStyleY9Tests {
    @Test("HLToggleStyle pins the native switch tint to HLText.secondary, not the .tint cascade")
    func toggleStylePinsOnTrackToSecondary() throws {
        let testFilePath = URL(fileURLWithPath: #filePath)
        let repoRoot = testFilePath
            .deletingLastPathComponent() // DesignSystem/
            .deletingLastPathComponent() // HealthLogTests/
            .deletingLastPathComponent() // repo root
        let target = repoRoot
            .appendingPathComponent("HealthLog")
            .appendingPathComponent("DesignSystem")
            .appendingPathComponent("HLToggleStyle.swift")
        let source = try String(contentsOf: target, encoding: .utf8)
        // The style must drive the NATIVE switch (full a11y + system
        // reduce-motion) rather than a hand-rolled control.
        #expect(source.contains(".toggleStyle(.switch)"))
        // The ON-track contrast must be pinned to HLText.secondary so it
        // stays mono and visible against the white thumb in Light + Dark,
        // independent of the App-root `.tint(HLText.primary)` cascade.
        #expect(source.contains(".tint(HLText.secondary)"))
    }

    @Test("HLToggleStyle renders a non-zero image in both ON and OFF states")
    @MainActor
    func toggleStyleRendersBothStates() {
        struct Host: View {
            @State var value: Bool
            var body: some View {
                Toggle("Test", isOn: $value)
                    .toggleStyle(HLToggleStyle())
                    .frame(width: 200, height: 44)
            }
        }
        let onRenderer = ImageRenderer(content: Host(value: true))
        onRenderer.scale = 1
        let offRenderer = ImageRenderer(content: Host(value: false))
        offRenderer.scale = 1
        #expect(onRenderer.uiImage != nil)
        #expect(offRenderer.uiImage != nil)
        #expect((onRenderer.uiImage?.size.width ?? 0) > 0)
        #expect((offRenderer.uiImage?.size.width ?? 0) > 0)
    }
}
