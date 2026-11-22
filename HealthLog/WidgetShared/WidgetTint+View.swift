import SwiftUI
import WidgetKit

public extension WidgetTint {
    init(_ mode: WidgetRenderingMode) {
        if mode == .fullColor {
            self = .fullColor
        } else if mode == .vibrant {
            self = .vibrant
        } else {
            self = .accented
        }
    }
}

public extension View {
    /// Puts this view into the accent group when ``WidgetTintPolicy`` says the
    /// layer belongs there. Full colour ignores the group, so this is a no-op
    /// on the default Home Screen.
    func widgetLayer(_ layer: WidgetLayer, in surface: WidgetSurface) -> some View {
        widgetAccentable(WidgetTintPolicy.isAccented(layer, in: surface))
    }
}
