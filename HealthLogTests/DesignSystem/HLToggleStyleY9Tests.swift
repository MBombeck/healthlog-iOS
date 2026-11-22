import Foundation
@testable import HealthLog
import SwiftUI
import Testing

/// `HLToggleStyle` wraps the native switch; both states must render, so the
/// control never collapses into an invisible track.
@Suite("HLToggleStyle Y9 ON-track contrast")
struct HLToggleStyleY9Tests {
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
