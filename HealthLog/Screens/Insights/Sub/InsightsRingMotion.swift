import SwiftUI

// MARK: - 1.4 B4 — the rings' living light comes to rest

/// Whether the score rings below may move. `true` for the first seconds after
/// the overview appears, then `false`: the breath of the tile glow and the
/// drift of the prism rim settle on their still frame.
///
/// Before this the motion ran for as long as the overview was on screen, eight
/// 20 fps clocks with blurs on four tiles. Nobody looks at a breathing glow for
/// a minute, but the main thread never went quiet: under XCUITest the overview
/// reported "main thread busy for 30 s" three times (B2-a), and VoiceOver and
/// the battery pay for the same frames. Reduce Motion and Low Power keep their
/// fully static path from the first frame.
private struct InsightsRingMotionKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var insightsRingMotionActive: Bool {
        get { self[InsightsRingMotionKey.self] }
        set { self[InsightsRingMotionKey.self] = newValue }
    }
}

/// Runs the rings' motion for ``WellnessTileMotion/activeSeconds`` each time
/// the host appears, then eases it to rest.
private struct InsightsRingMotionWindow: ViewModifier {
    @State private var active = true

    func body(content: Content) -> some View {
        content
            .environment(\.insightsRingMotionActive, active)
            .task {
                active = true
                try? await Task.sleep(for: .seconds(WellnessTileMotion.activeSeconds))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: WellnessTileMotion.settleSeconds)) { active = false }
            }
    }
}

extension View {
    /// 1.4 B4 — bound the score rings' motion below this view to a short
    /// window after it appears.
    func insightsRingMotionWindow() -> some View {
        modifier(InsightsRingMotionWindow())
    }
}
