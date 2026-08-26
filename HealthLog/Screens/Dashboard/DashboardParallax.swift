import SwiftUI

/// W-IMPL-MOTION-POLISH (v0.5.5.1) — Dashboard scroll-driven greeting fade.
///
/// **Wave 2 / 2.4 — the HERO PARALLAX WAS REMOVED (operator b227).** The hero no
/// longer translates at `HLMotion.parallaxRate`; the `DashboardParallaxOffset`
/// wrapper and the `heroOffset(for:reduceMotion:)` math are gone. Rationale: the
/// web hero has no parallax (parity), HIG `scroll-views` cautions that custom
/// scroll effects break Look-to-Scroll, and on device the effect made the hero
/// read as detached from its own rail.
///
/// What REMAINS is the greeting fade: the greeting block in `DashboardHeader`
/// fades from full opacity to `HLMotion.parallaxFadeFloor` over the first
/// `HLMotion.parallaxFadeDistance` points of downward scroll.
///
/// **Reduce-motion contract:** when `accessibilityReduceMotion` is `true`,
/// the parallax modifier resolves to the identity transform (no offset, no
/// opacity ramp). The rest of the layout stays bit-identical.
///
/// **Implementation (v0.14.8 AUDIT-HOME M11):** the original
/// `GeometryReader`/`PreferenceKey` probe wrote a `@State` on
/// `DashboardScreen` every scrolled frame, re-evaluating the ENTIRE screen
/// body (header, hero, grid construction, `orderedMetrics` dictionary
/// builds) per frame. The stated rationale — "supports the iOS-18 baseline
/// without conditional compile" — was outdated: `onScrollGeometryChange` IS
/// iOS-18.0 API and the min target is 18.0. The scroll offset now flows
/// through ``DashboardParallaxModel`` (an `@Observable` box): the
/// `ScrollView` writes it via `onScrollGeometryChange`, and only the view
/// that actually READS it (the greeting block inside `DashboardHeader`)
/// re-evaluates per frame — the tile stack stays untouched. The math stays
/// in the pure `DashboardParallaxMath` helper — see `DashboardParallaxTests`.
enum DashboardParallaxMath {
    // Wave 2 / 2.4 — `heroOffset(for:reduceMotion:)` was DELETED together with
    // its only caller, `DashboardParallaxOffset`. See the type doc above.

    /// Returns the greeting block's opacity for a given scroll offset.
    /// Linear ramp from 1.0 down to `parallaxFadeFloor` over the first
    /// `parallaxFadeDistance` points. Reduce-motion pins to 1.0.
    static func greetingOpacity(for scrollOffset: CGFloat, reduceMotion: Bool) -> Double {
        guard !reduceMotion else { return 1.0 }
        let positive = max(0, scrollOffset)
        let progress = min(1.0, Double(positive / HLMotion.parallaxFadeDistance))
        let floor = HLMotion.parallaxFadeFloor
        return 1.0 - (1.0 - floor) * progress
    }
}

/// v0.14.8 AUDIT-HOME M11 — observable box for the live scroll offset.
///
/// The ScrollView's `onScrollGeometryChange` writes `scrollOffset` per
/// frame; because the write happens inside an action closure (not the
/// screen's `body`), `DashboardScreen` itself never registers an
/// Observation dependency on it. Only the small views that read the
/// property (`DashboardParallaxOffset`, the greeting block in
/// `DashboardHeader`) invalidate while scrolling.
@MainActor
@Observable
final class DashboardParallaxModel {
    /// Canonical "amount scrolled" — positive when the user scrolled DOWN
    /// (the top of the content moved off-screen), 0 at rest. Overscroll
    /// above the top goes negative; the math helpers clamp it.
    var scrollOffset: CGFloat = 0
}

// Wave 2 / 2.4 — `DashboardParallaxOffset` (the per-frame hero-offset wrapper)
// was DELETED. The hero no longer translates while scrolling; the greeting fade
// reads `DashboardParallaxModel` directly inside `DashboardHeader`.

// MARK: - Matched-geometry helper (W-IMPL-MOTION-POLISH, v0.5.5.1)

/// Stable identifier prefix shared by the source tile + destination
/// `ChartDetailScreen.HeroStrip`. Encodes the `MetricKind` so two distinct
/// metrics don't collide inside the same namespace.
enum DashboardMatchedGeometryID {
    /// Identifier for the per-metric value text (source = tile number,
    /// destination = chart-detail hero number).
    static func value(for kind: MetricKind) -> String {
        "dashboard.tile.value.\(kind.rawValue)"
    }
}

/// Conditionally applies `matchedGeometryEffect` when the host namespace is
/// non-nil. Reduce-motion callers MUST pass `nil` themselves — this helper
/// does not read the environment, so callers stay in control of the gate.
extension View {
    @ViewBuilder
    func matchedTileGeometry(id: String, in namespace: Namespace.ID?) -> some View {
        if let namespace {
            matchedGeometryEffect(id: id, in: namespace)
        } else {
            self
        }
    }
}
