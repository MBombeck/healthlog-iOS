import SwiftUI

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
/// The rule is an ordering, not a lookup: `accessibilityReduceTransparency` is
/// evaluated **before** `#available`. A preference the user set in Settings is
/// not conditional on which iOS the device happens to be running — an iOS-26
/// device must not silently opt back into glass because a newer API exists.
/// `LiquidGlass.swift` used to branch on availability alone, which is exactly
/// how the preference stopped reaching every glass surface on iOS 26.
///
/// The resolution is a pure function of two booleans so all four combinations
/// are testable without writing the (read-only) environment key. Availability
/// is a *separate* property for the same reason: it is the only part that
/// cannot be driven from a test.
public enum HLSurfaceOpacity {
    /// What a call-site must actually paint.
    public enum Resolution: String, Equatable, Sendable, CaseIterable {
        /// The user asked for opacity — paint the semantic solid fill. This is
        /// the answer on iOS 18 *and* on iOS 26.
        case opaque
        /// iOS 26+ Liquid Glass, the progressive enhancement.
        case glass
        /// The iOS 18–25 baseline treatment (solid surface fill / material).
        case material
    }

    /// - Parameters:
    ///   - reduceTransparency: the accessibility preference, read by the caller
    ///     from the environment (a `View` can; a `View` extension method cannot).
    ///   - glassAvailable: whether the iOS 26 glass APIs exist at runtime.
    public static func resolve(reduceTransparency: Bool, glassAvailable: Bool) -> Resolution {
        if reduceTransparency { return .opaque }
        return glassAvailable ? .glass : .material
    }

    /// The runtime availability the process actually has. Deliberately *not*
    /// folded into ``resolve(reduceTransparency:glassAvailable:)`` so the policy
    /// itself stays a pure function.
    public static var glassAvailable: Bool {
        if #available(iOS 26.0, *) { true } else { false }
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
