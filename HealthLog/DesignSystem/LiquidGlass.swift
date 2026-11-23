import SwiftUI

/// Helpers for Apple Liquid Glass.
///
/// These wrappers give each glass treatment one call-site and consult the
/// Reduce-Transparency preference (`HLSurfaceOpacity`) before painting: glass
/// by default, the existing material / surface treatment as the opaque
/// fallback.
///
/// **Don't adopt** (per A6 §2):
/// - Custom Liquid-Glass shaders / specular highlights — too risky for v0.4.0
/// - `GlassEffectContainer` outside hero spots — wait for screenshots-driven need
///
/// **Free with Xcode-26 recompile** (no work needed):
/// - Standard `TabView` paints Liquid Glass on iOS 26+ automatically.
/// - Standard `NavigationStack` toolbar items get the system glass group.
/// - Standard `sheet` with at-least-one partial detent picks up glass.
///
/// **What we add on top (v0.5.x C-9 — additive chrome polish per R1
/// Strategy C, chrome-only, content-layer stays mono):**
///
/// - `hlGlassBackground(_:in:fallback:)` — used by tiles/cards that want
///   glass, with our existing surface treatment as the opaque fallback.
/// - `hlGlassEffect(_:in:)` — bare opt-in for floating buttons / chips.
/// - `hlBottomBar { }` — the bar at the bottom of a sheet or a selection
///   (consent buttons, the coach's input, bulk actions), on the system's
///   `safeAreaBar`, which brings the scroll edge under it; no material.
/// - `hlScrollEdgeSoft()` — kept as a name only. iOS 26 draws the soft edge
///   under every bar on its own, so the modifier changes nothing any more.
public extension View {
    /// Applies a Liquid Glass background, or under Reduce Transparency the
    /// supplied surface fill.
    ///
    /// - Parameters:
    ///   - shape: clipping shape (defaults to the card-radius rounded rect).
    ///   - fallback: solid fill under Reduce Transparency (defaults to `HLColor.surface`).
    func hlGlassBackground<Shape: SwiftUI.Shape>(
        in shape: Shape = RoundedRectangle(cornerRadius: HLRadius.card, style: .continuous),
        fallback: Color = HLColor.surface
    ) -> some View {
        // Routed through a small helper, which is where `HLSurfaceOpacity`
        // is consulted.
        modifier(HLGlassSurfaceModifier(shape: shape, variant: .regular, fallback: fallback))
    }

    /// Opt-in glass effect on a floating control (FAB, pill button, etc.).
    /// Fallback paints the supplied background fill at the same shape.
    ///
    /// - Parameter interactive: opts the glass into the system
    ///   `.interactive()` treatment (scale / illumination / shimmer on touch).
    ///   Use ONLY for tappable floating controls — never on static chrome.
    ///   No-op on the opaque fallback (plain fill).
    func hlGlassEffect<Shape: SwiftUI.Shape>(
        in shape: Shape = Capsule(),
        interactive: Bool = false,
        fallback: Color = HLColor.backgroundEleva
    ) -> some View {
        modifier(
            HLGlassSurfaceModifier(
                shape: shape,
                variant: interactive ? .interactive : .regular,
                fallback: fallback
            )
        )
    }

    /// CTA button-style helper — paints the `.glassProminent` style on the
    /// system's Liquid-Glass path and falls back to `.borderedProminent` under
    /// Reduce Transparency. **Chrome-only contract (STANDARDS §5):** apply ONLY
    /// to a screen's primary call-to-action button(s), never to content-card
    /// chrome. Folds the Reduce-Transparency branch into one call-site so CTAs
    /// don't each repeat it.
    func hlGlassButtonStyle() -> some View {
        modifier(HLGlassButtonStyleModifier())
    }

    /// No longer changes anything. On iOS 26 the automatic scroll edge under
    /// a navigation bar or toolbar on iPhone is the soft one, so setting it
    /// by hand gave the same picture on the 28 screens that did and left the
    /// others out. Remove the call when a screen is touched anyway.
    func hlScrollEdgeSoft() -> some View {
        self
    }

    /// The bar at the bottom edge of a sheet or a page: pinned buttons, an
    /// input line, the actions of a selection. It rides the system's
    /// `safeAreaBar`, so the content scrolls under it behind the system's
    /// scroll edge and no material is painted (glass belongs to the controls
    /// in the bar). Page margins at the sides, a small gap below.
    func hlBottomBar(@ViewBuilder _ bar: () -> some View) -> some View {
        safeAreaBar(edge: .bottom, spacing: 0) {
            bar()
                .padding(.horizontal, HLBottomBarMetrics.horizontalInset)
                .padding(.vertical, HLBottomBarMetrics.verticalInset)
        }
    }
}

// MARK: - Reduce-Transparency-aware plumbing

/// Reads the accessibility preference a `View` extension method cannot see and
/// hands it to the policy. Every `.hlGlass*` painting helper goes through one of
/// these three modifiers, so there is exactly one place per helper where the
/// preference could be forgotten — and none of them can forget it silently,
/// because the resolution is a `switch` over an exhaustive enum.
private struct HLGlassSurfaceModifier<S: Shape>: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let shape: S
    let variant: HLGlassEffect.Variant
    let fallback: Color

    func body(content: Content) -> some View {
        HLGlassEffect.apply(
            content,
            in: shape,
            variant: variant,
            fallback: fallback,
            reduceTransparency: reduceTransparency
        )
    }
}

private struct HLGlassButtonStyleModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        HLGlassEffect.buttonStyled(content, reduceTransparency: reduceTransparency)
    }
}

/// The measures of ``SwiftUI/View/hlBottomBar(_:)``.
public enum HLBottomBarMetrics {
    /// The page margin, so the bar's buttons line up with the cards.
    public static let horizontalInset: CGFloat = HLLayout.pageMargin
    public static let verticalInset: CGFloat = HLSpace.sm
}

/// Routes the glass-effect application through a single helper so the
/// Reduce-Transparency policy is consulted in one place.
///
/// Internal — call-sites should use the `.hlGlass*` view modifiers above.
/// `@MainActor` because `View` and `ViewModifier` are: the style properties
/// these helpers reach for (`.borderedProminent`, `.glassProminent`) are
/// main-actor-isolated, and the isolation used to arrive implicitly from the
/// enclosing `extension View`. Naming it here keeps the helpers callable from
/// exactly the places that could call them before.
@MainActor
enum HLGlassEffect {
    enum Variant {
        case regular
        /// `.regular.interactive()` — touch-responsive glass for floating
        /// controls (edit pills, Coach composer). iOS 26+ only.
        case interactive
    }

    /// Paints the surface the policy asked for: glass, or under Reduce
    /// Transparency the caller's solid fallback fill.
    @ViewBuilder
    static func apply(
        _ content: some View,
        in shape: some Shape,
        variant: Variant,
        fallback: Color,
        reduceTransparency: Bool
    ) -> some View {
        switch HLSurfaceOpacity.resolve(reduceTransparency: reduceTransparency) {
        case .glass:
            switch variant {
            case .regular:
                content.glassEffect(.regular, in: shape)
            case .interactive:
                content.glassEffect(.regular.interactive(), in: shape)
            }
        case .opaque:
            content.background(fallback, in: shape)
        }
    }

    /// CTA style. `.borderedProminent` is opaque, so it is the
    /// Reduce-Transparency answer.
    @ViewBuilder
    static func buttonStyled(_ content: some View, reduceTransparency: Bool) -> some View {
        switch HLSurfaceOpacity.resolve(reduceTransparency: reduceTransparency) {
        case .glass:
            content.buttonStyle(.glassProminent)
        case .opaque:
            content.buttonStyle(.borderedProminent)
        }
    }
}

/// Groups adjacent glass controls so they merge / flex / morph as one fluid
/// surface (the signature `GlassEffectContainer` behaviour): glass views
/// closer than `spacing` blend into one.
struct HLGlassEffectContainer<Content: View>: View {
    let spacing: CGFloat?
    @ViewBuilder let content: () -> Content

    init(spacing: CGFloat? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        GlassEffectContainer(spacing: spacing) {
            content()
        }
    }
}
