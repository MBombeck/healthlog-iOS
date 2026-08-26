import CoreGraphics
import Foundation
@testable import HealthLog
import Testing

/// **Dashboard scroll-driven greeting fade + matched-geometry contracts.**
///
/// **Wave 2 / 2.4 update.** The four hero-offset tests that pinned
/// `DashboardParallaxMath.heroOffset` (hero translates upward at
/// `HLMotion.parallaxRate`, clamps on overscroll, identity under reduce-motion)
/// were REMOVED, not merely disabled: the hero parallax itself was removed on
/// the operator's b227 decision (web parity — the web hero has no parallax; HIG
/// `scroll-views` cautions that custom scroll effects break Look-to-Scroll), so
/// `heroOffset` and its `DashboardParallaxOffset` caller no longer exist. There
/// is nothing left to assert about a hero offset; asserting "offset is always 0"
/// would pin an implementation detail of a deleted feature.
///
/// What this suite still pins:
///
/// 1. Greeting fades from 1.0 → `HLMotion.parallaxFadeFloor` linearly over
///    the first `HLMotion.parallaxFadeDistance` points of scroll.
/// 2. Reduce-motion bypasses the fade (opacity pinned to 1.0).
/// 3. The matched-geometry identifier convention (source tile ↔ destination
///    hero strip must compute the same id per `MetricKind`).
@Suite("Dashboard greeting fade + matched-geometry contracts")
struct DashboardParallaxTests {
    // MARK: - Greeting opacity math

    @Test("Greeting opacity is 1.0 at scrollOffset zero")
    func greetingOpaqueAtIdle() {
        #expect(DashboardParallaxMath.greetingOpacity(for: 0, reduceMotion: false) == 1.0)
    }

    @Test("Greeting opacity reaches the fade floor at parallaxFadeDistance")
    func greetingOpacityHitsFloor() {
        let result = DashboardParallaxMath.greetingOpacity(
            for: HLMotion.parallaxFadeDistance,
            reduceMotion: false
        )
        #expect(result == HLMotion.parallaxFadeFloor)
    }

    @Test("Greeting opacity clamps at the floor past parallaxFadeDistance")
    func greetingOpacityClampsBelowFloor() {
        let result = DashboardParallaxMath.greetingOpacity(
            for: HLMotion.parallaxFadeDistance * 4,
            reduceMotion: false
        )
        #expect(result == HLMotion.parallaxFadeFloor)
    }

    @Test("Greeting opacity ramps linearly between idle and the floor")
    func greetingOpacityHalfwayDown() {
        let halfway = HLMotion.parallaxFadeDistance / 2
        let result = DashboardParallaxMath.greetingOpacity(for: halfway, reduceMotion: false)
        let expected = 1.0 - (1.0 - HLMotion.parallaxFadeFloor) * 0.5
        // Use a small epsilon — `progress` is computed via Double arithmetic
        // and the half-way fraction is exact, but we keep tolerance for safety.
        #expect(abs(result - expected) < 0.0001)
    }

    @Test("Greeting opacity stays at 1.0 under reduce-motion regardless of scroll")
    func greetingOpacityIgnoredUnderReduceMotion() {
        let result = DashboardParallaxMath.greetingOpacity(
            for: HLMotion.parallaxFadeDistance * 2,
            reduceMotion: true
        )
        #expect(result == 1.0)
    }

    // MARK: - Matched-geometry identifier convention

    /// The destination `ChartDetailScreen.HeroStrip` and the source
    /// `HLDashboardTile.valueRow` must compute the **same** identifier from
    /// the metric kind — otherwise SwiftUI treats the source + destination
    /// as unrelated elements and silently drops the shared-element animation.
    @Test("DashboardMatchedGeometryID.value is stable per MetricKind across call sites")
    func matchedGeometryIdEncodesKind() {
        for kind in MetricKind.allCases {
            let id = DashboardMatchedGeometryID.value(for: kind)
            #expect(id == "dashboard.tile.value.\(kind.rawValue)")
        }
    }

    /// Two distinct `MetricKind`s must never collide on the same identifier;
    /// otherwise tapping Steps + then Pulse in quick succession would re-use
    /// the same matched geometry and paint a wrong-source flight.
    @Test("DashboardMatchedGeometryID.value differs across distinct MetricKinds")
    func matchedGeometryIdDistinctPerKind() {
        let ids = MetricKind.allCases.map(DashboardMatchedGeometryID.value(for:))
        #expect(Set(ids).count == ids.count)
    }
}
