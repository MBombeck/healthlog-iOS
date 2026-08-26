import SwiftUI

/// Progressive-enhancement helpers for Apple Liquid Glass (iOS 26+).
///
/// **Decision context** — A6 §2: iOS 18 stays our baseline (PROJECT_GUIDE.md
/// `Min iOS: 18.0`). Liquid Glass is iOS 26+ only — `glassEffect(_:in:)`
/// APIs and `GlassEffectContainer` all gate on `#available(iOS 26, *)`.
/// Real-world May-2026 reach of iOS 26 is still well below 50%, so glass
/// stays **progressive enhancement, not baseline**.
///
/// These wrappers fold the availability check into the call-site so views
/// can opt-in without sprinkling `if #available` blocks across the screen
/// library. On iOS 18-25 the fallback is the existing material / surface
/// treatment we already ship; iOS 26+ uses the new APIs.
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
///   glass on iOS 26 and our existing surface treatment otherwise.
/// - `hlGlassEffect(_:in:)` — bare opt-in for floating buttons / chips.
/// - `hlTabBarMinimizeOnScroll()` — opts the TabView into the iOS 26
///   `tabBarMinimizeBehavior(.onScrollDown)` so the tab bar collapses out
///   of the way while reading long lists (Dashboard, Insights, Meds,
///   Mehr). No-op on iOS 18-25.
/// - `hlScrollEdgeSoft()` — opts a ScrollView into the iOS 26 soft
///   scroll-edge effect at the top edge, so content blurs behind the
///   nav-bar's Liquid Glass instead of clipping cleanly against it. The
///   single iOS-26 polish that turns the toolbar into a *real* glass
///   surface. No-op on iOS 18-25 (system stays flat-translucent).
///
/// All call-sites read cleanly regardless of platform availability.
public extension View {
    /// Applies a Liquid Glass background on iOS 26+, falls back to the
    /// supplied surface fill otherwise.
    ///
    /// - Parameters:
    ///   - shape: clipping shape (defaults to the card-radius rounded rect).
    ///   - fallback: solid fill on iOS 18-25 (defaults to `HLColor.surface`).
    func hlGlassBackground<Shape: SwiftUI.Shape>(
        in shape: Shape = RoundedRectangle(cornerRadius: HLRadius.card, style: .continuous),
        fallback: Color = HLColor.surface
    ) -> some View {
        // `glassEffect(.regular, in:)` ships in iOS 26. We avoid hard-
        // referencing the symbol here (so 18.0-target build stays clean
        // when SDK lookups fail) by routing through a small helper — which
        // is also where `HLSurfaceOpacity` is consulted, ahead of any
        // availability check.
        modifier(HLGlassSurfaceModifier(shape: shape, variant: .regular, fallback: fallback))
    }

    /// Opt-in glass effect on a floating control (FAB, pill button, etc.).
    /// Fallback paints the supplied background fill at the same shape.
    ///
    /// - Parameter interactive: on iOS 26+, opts the glass into the system
    ///   `.interactive()` treatment (scale / illumination / shimmer on touch).
    ///   Use ONLY for tappable floating controls — never on static chrome.
    ///   No-op on the iOS 18-25 fallback (plain fill).
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

    /// **v0.5.2-R1 reconcile (2026-05-17): now a no-op on every iOS
    /// version.** The previous iOS-26 path opted the TabView into
    /// `tabBarMinimizeBehavior(.onScrollDown)`. A8 centred the "Erfassen"
    /// tab as the primary capture entry-point, and operator design-QA
    /// flagged that minimising the bar also hid Erfassen — defeating the
    /// "Erfassen is always one tap away" contract A8 just shipped. The
    /// modifier stays in the call-graph (kept callable from
    /// `AuthenticatedShell`) so future iOS-26 work can revisit a
    /// content-aware variant (e.g. de-emphasise non-Erfassen tabs on
    /// scroll without hiding the centred capture tab); the call-site does
    /// not need to be ripped out today.
    ///
    /// v0.6+ exploration tracked in
    /// `.planning/v05x-marathon/V052-R1-design-reconcile-report.md`:
    /// (B) keep TabBar visible but de-emphasise non-Erfassen tabs on
    /// scroll, (C) floating Erfassen pill that remains while others
    /// minimise. Neither ships in v0.5.2.
    func hlTabBarMinimizeOnScroll() -> some View {
        self
    }

    /// iOS 26+: assign a stable glass-effect identity inside a
    /// `GlassEffectContainer` so adjacent glass controls merge / flex / morph
    /// (the signature iOS-26 fluid-glass behaviour). No-op on iOS 18-25, where
    /// the controls simply sit side-by-side without the union effect.
    ///
    /// Deliberately **not** routed through `HLSurfaceOpacity`: this assigns an
    /// identity and paints nothing. When the preference sends its siblings to
    /// the opaque fill there is no glass left to merge, so the identity is inert
    /// rather than wrong. The same holds for `HLGlassEffectContainer`.
    ///
    /// - Parameters:
    ///   - id: a value unique within the enclosing container namespace.
    ///   - namespace: the `@Namespace` shared with sibling glass controls.
    @ViewBuilder
    func hlGlassEffectID(_ id: some Hashable & Sendable, in namespace: Namespace.ID) -> some View {
        if #available(iOS 26.0, *) {
            glassEffectID(id, in: namespace)
        } else {
            self
        }
    }

    /// CTA button-style helper — paints the iOS-26 `.glassProminent` style on
    /// the system's Liquid-Glass path and falls back to `.borderedProminent`
    /// on iOS 18-25. **Chrome-only contract (STANDARDS §5):** apply ONLY to a
    /// screen's primary call-to-action button(s), never to content-card chrome.
    /// Folds the `#available` branch into one call-site so CTAs don't sprinkle
    /// availability blocks.
    func hlGlassButtonStyle() -> some View {
        modifier(HLGlassButtonStyleModifier())
    }

    /// iOS 26+: enable the soft scroll-edge effect so scrollable content
    /// blurs into the navigation-bar / toolbar Liquid Glass instead of
    /// clipping cleanly. The single modifier that makes the toolbar feel
    /// like a real glass surface on iOS 26. iOS 18-25: no-op (system
    /// keeps the flat translucent nav-bar). Apply on the inner `ScrollView`
    /// of any pushed / root screen that wants the glass scroll-edge.
    func hlScrollEdgeSoft() -> some View {
        modifier(HLScrollEdgeSoftModifier())
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

private struct HLScrollEdgeSoftModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        HLGlassEffect.scrollEdge(content, reduceTransparency: reduceTransparency)
    }
}

/// Routes the glass-effect application through a single availability-gated
/// helper so individual call-sites don't carry an `#available` block.
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

    /// Paints the surface the policy asked for. `.opaque` and `.material` land
    /// on the *same* solid fill, which is the point: the fallback the app has
    /// always shipped on iOS 18–25 is exactly the legible surface Reduce
    /// Transparency needs on iOS 26, so honouring the preference costs no new
    /// appearance and cannot drift away from the baseline one.
    @ViewBuilder
    static func apply(
        _ content: some View,
        in shape: some Shape,
        variant: Variant,
        fallback: Color,
        reduceTransparency: Bool
    ) -> some View {
        switch HLSurfaceOpacity.resolve(
            reduceTransparency: reduceTransparency,
            glassAvailable: HLSurfaceOpacity.glassAvailable
        ) {
        case .glass:
            glass(content, in: shape, variant: variant)
        case .opaque, .material:
            content.background(fallback, in: shape)
        }
    }

    /// CTA style. `.borderedProminent` is opaque, so the Reduce-Transparency
    /// answer is the iOS 18–25 answer here too.
    @ViewBuilder
    static func buttonStyled(_ content: some View, reduceTransparency: Bool) -> some View {
        switch HLSurfaceOpacity.resolve(
            reduceTransparency: reduceTransparency,
            glassAvailable: HLSurfaceOpacity.glassAvailable
        ) {
        case .glass:
            glassButton(content)
        case .opaque, .material:
            content.buttonStyle(.borderedProminent)
        }
    }

    /// The soft scroll edge is a blur-through: content is deliberately visible
    /// *inside* the toolbar. Under Reduce Transparency we do not opt into it and
    /// leave the system's own defined edge standing — which is precisely the
    /// iOS 18–25 behaviour, so no third appearance is invented here either.
    @ViewBuilder
    static func scrollEdge(_ content: some View, reduceTransparency: Bool) -> some View {
        switch HLSurfaceOpacity.resolve(
            reduceTransparency: reduceTransparency,
            glassAvailable: HLSurfaceOpacity.glassAvailable
        ) {
        case .glass:
            softScrollEdge(content)
        case .opaque, .material:
            content
        }
    }

    @ViewBuilder
    private static func glass(_ content: some View, in shape: some Shape, variant: Variant) -> some View {
        if #available(iOS 26.0, *) {
            switch variant {
            case .regular:
                content.glassEffect(.regular, in: shape)
            case .interactive:
                content.glassEffect(.regular.interactive(), in: shape)
            }
        } else {
            content
        }
    }

    @ViewBuilder
    private static func glassButton(_ content: some View) -> some View {
        if #available(iOS 26.0, *) {
            content.buttonStyle(.glassProminent)
        } else {
            content.buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    private static func softScrollEdge(_ content: some View) -> some View {
        if #available(iOS 26.0, *) {
            content.scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            content
        }
    }
}

/// Groups adjacent glass controls so they merge / flex / morph as one fluid
/// surface (the signature iOS-26 `GlassEffectContainer` behaviour). On iOS
/// 18-25 it degrades to a plain pass-through container, so the children just
/// lay out normally. Children opt into the union via `.hlGlassEffectID(_:in:)`.
///
/// Usage:
/// ```swift
/// @Namespace private var glassNS
/// HLGlassEffectContainer(spacing: HLSpace.sm) {
///     fieldView.hlGlassEffectID("field", in: glassNS)
///     sendButton.hlGlassEffectID("send", in: glassNS)
/// }
/// ```
struct HLGlassEffectContainer<Content: View>: View {
    let spacing: CGFloat?
    @ViewBuilder let content: () -> Content

    init(spacing: CGFloat? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content()
            }
        } else {
            content()
        }
    }
}
