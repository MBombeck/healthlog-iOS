import SwiftUI
import UIKit

/// Respektiert `accessibilityReduceMotion`: deaktiviert die Animation,
/// wenn der User Reduce-Motion aktiviert hat.
public extension View {
    func hlAnimation(_ animation: Animation?, value: some Equatable) -> some View {
        modifier(ReduceMotionAnimationModifier(animation: animation, value: value))
    }
}

private struct ReduceMotionAnimationModifier<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation?
    let value: V

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

/// **The canonical interaction region for a small-glyph control.**
///
/// Guarantees `HLHitTarget.minimum` in both directions and makes the whole of
/// that region hit-testable — and does nothing else. It deliberately does not
/// scale the glyph (the icon keeps the size its typography chose), does not add
/// visual padding (a `minWidth`/`minHeight` frame grows only the controls that
/// were too small, so a control already at or above 44 is untouched), and does
/// not touch accessibility semantics (a status glyph that is not interactive
/// must not become an element just because something grew around it).
///
/// Apply it to the *interactive* view — the `Button`, or its label — never to a
/// decorative `Image`. The hit shape is deliberately the plain rectangle of the
/// grown region and is not a parameter: a control that needs a different one
/// composes its own `.contentShape(_:)` on top, which is one obvious line, and
/// leaves this modifier with exactly one thing to be wrong about.
public extension View {
    func hlMinimumHitTarget() -> some View {
        frame(minWidth: HLHitTarget.minimum, minHeight: HLHitTarget.minimum)
            .contentShape(Rectangle())
    }
}

/// **The one decision every translucent surface has to make, made once.**
///
/// `accessibilityReduceTransparency` decides before any glass API is reached.
/// A preference the user set in Settings must not be skipped because a glass
/// API exists. `LiquidGlass.swift` used to branch on availability alone, which
/// is exactly how the preference stopped reaching every glass surface on iOS 26.
///
/// The resolution is a pure function so both answers are testable without
/// writing the (read-only) environment key.
public enum HLSurfaceOpacity {
    /// What a call-site must actually paint.
    public enum Resolution: String, Equatable, Sendable, CaseIterable {
        /// The user asked for opacity — paint the semantic solid fill.
        case opaque
        /// Liquid Glass.
        case glass
    }

    /// - Parameter reduceTransparency: the accessibility preference, read by
    ///   the caller from the environment (a `View` can; a `View` extension
    ///   method cannot).
    public static func resolve(reduceTransparency: Bool) -> Resolution {
        reduceTransparency ? .opaque : .glass
    }
}

/// Material-Hintergrund mit Solid-Fallback bei `accessibilityReduceTransparency`.
///
/// Single source of truth for "material with a legible solid fallback". When the
/// user enables Reduce Transparency the material would otherwise wash out — this
/// swaps it for an opaque colour so consent/offline/legal surfaces stay readable.
public struct HLMaterialBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private let material: Material
    private let solidColor: Color

    public init(_ material: Material = .ultraThinMaterial, solidFallback: Color = HLColor.backgroundEleva) {
        self.material = material
        solidColor = solidFallback
    }

    public var body: some View {
        Self.resolved(reduceTransparency: reduceTransparency, material: material, solidColor: solidColor)
    }

    /// The env-independent resolution of the background — exposed so the
    /// reduce-transparency branch is renderable in tests without having to write
    /// the (read-only) `accessibilityReduceTransparency` environment key.
    @ViewBuilder
    static func resolved(reduceTransparency: Bool, material: Material, solidColor: Color) -> some View {
        if reduceTransparency {
            solidColor
        } else {
            Rectangle().fill(material)
        }
    }
}

/// A11Y (1.5) — `withAnimation` that honours Reduce Motion: with the setting
/// on, the change lands without the animation (a section unfolds at once
/// instead of sliding open). For actions, where no view environment is at
/// hand; inside a view body `hlAnimation(_:value:)` does the same.
@MainActor
func withHLAnimation<Result>(_ animation: Animation?, _ body: () throws -> Result) rethrows -> Result {
    try withAnimation(UIAccessibility.isReduceMotionEnabled ? nil : animation, body)
}
