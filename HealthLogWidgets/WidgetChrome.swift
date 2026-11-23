import SwiftUI
import WidgetKit

/// The "Taken" pill for tinted and clear rendering.
///
/// The full-colour pill paints a light label on a light fill; once the system
/// drops the hues both become the same tone and the label vanishes. Here the
/// fill stays faint and the outline carries the shape, so the label reads in
/// every rendering. The armed state keeps its own word and a heavier outline.
struct WidgetTintedPillStyle: ViewModifier {
    let pendingConfirm: Bool

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity)
            .frame(minHeight: WidgetMetrics.minTapTarget)
            .background(
                RoundedRectangle(cornerRadius: WidgetMetrics.controlCornerRadius, style: .continuous)
                    .fill(LAColor.accent.opacity(pendingConfirm ? 0.24 : 0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: WidgetMetrics.controlCornerRadius, style: .continuous)
                    .strokeBorder(LAColor.accent, lineWidth: pendingConfirm ? 2 : 1)
            )
    }
}

extension View {
    /// The canonical pill in full colour, the outlined pill everywhere else.
    @ViewBuilder
    func widgetTakenPill(pendingConfirm: Bool, tint: WidgetTint) -> some View {
        if tint == .fullColor {
            laMedTakenPill(pendingConfirm: pendingConfirm)
        } else {
            modifier(WidgetTintedPillStyle(pendingConfirm: pendingConfirm))
        }
    }
}
