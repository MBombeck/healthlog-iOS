import SwiftUI

/// v0.11 W52-3 / Task #48 — drives the Insights tab strip's hide-on-scroll.
///
/// The strip lives in `InsightsContainerScreen`'s `.safeAreaInset(edge: .top)`.
/// To declutter while reading a long metric column, it HIDES on scroll-down and
/// REVEALS on scroll-up — exactly the web strip's behaviour.
///
/// **W44 safety (the hang we must not reintroduce).** The horizontal pager pins
/// each page with `.containerRelativeFrame(.horizontal)` ONLY and bridges
/// `scrolledID ↔ selection` via guarded mirrors. Coupling ANY vertical
/// measurement back into that resolver re-triggers the AttributeGraph layout
/// loop that froze build 116. This model is therefore deliberately decoupled
/// from the pager: each page reports its OWN INNER vertical scroll offset (via
/// `.onScrollGeometryChange` on the inner `ScrollView` of `InsightsScreen` /
/// `InsightsMetricScreen`) into `report(offset:)`. The container reads only the
/// resulting `hidden` flag and animates the strip's **offset + opacity** — never
/// its height, never the safeAreaInset's reported size. The pager's
/// `.containerRelativeFrame` / `.scrollPosition` resolver therefore never re-runs
/// as a function of scroll, so the W44 coupling cannot re-form.
///
/// `@MainActor @Observable` per the project state doctrine (no `ObservableObject`,
/// no Combine). Injected into the environment by the container; the two inner
/// screens read it back to push their offset up.
@MainActor
@Observable
final class InsightsStripVisibility {
    /// `true` → the strip is slid up under the nav + faded out. The container
    /// animates the transition (reduce-motion-gated at the call site).
    private(set) var hidden = false

    /// The last inner-scroll offset we evaluated a direction against. `nil`
    /// until the first report, so the very first sample establishes a baseline
    /// without spuriously toggling.
    private var lastOffset: CGFloat?

    /// Direction hysteresis — a small dead-band so a single jittery frame (or a
    /// rubber-band overscroll wobble) doesn't flip the strip. Only a scroll
    /// movement that exceeds this many points in one direction since the last
    /// pivot changes the hidden state.
    private static let directionThreshold: CGFloat = 12

    /// Top dwell zone — within this many points of the very top the strip is
    /// always revealed, so the operator never lands at the top of a page with a
    /// hidden strip (the strip must frame the header at rest).
    private static let topRevealZone: CGFloat = 8

    /// Report a fresh inner-scroll vertical content offset from one of the
    /// pages. Positive `offset` = scrolled down (content moved up under the nav).
    ///
    /// Pure direction logic with hysteresis — NO view-layout work happens here,
    /// so this can never feed a measurement back into the horizontal pager.
    func report(offset: CGFloat) {
        // Near the top → always reveal. Reset the pivot so the next downward
        // move is measured from the top, not from a stale deep-scroll value.
        if offset <= Self.topRevealZone {
            lastOffset = offset
            if hidden { hidden = false }
            return
        }

        guard let last = lastOffset else {
            // First real sample below the top — establish the baseline only.
            lastOffset = offset
            return
        }

        let delta = offset - last
        if delta > Self.directionThreshold {
            // Scrolled DOWN past the dead-band → hide. Re-pivot here so a later
            // small upward wobble doesn't immediately reveal.
            if !hidden { hidden = true }
            lastOffset = offset
        } else if delta < -Self.directionThreshold {
            // Scrolled UP past the dead-band → reveal.
            if hidden { hidden = false }
            lastOffset = offset
        }
        // |delta| ≤ threshold → within the dead-band: hold state AND hold the
        // pivot, so many tiny same-direction frames still accumulate toward a
        // flip (we don't reset `lastOffset` here).
    }

    /// Reset to the revealed baseline — called when the operator switches pages,
    /// so a new page always opens with the strip framing its header.
    func reset() {
        lastOffset = nil
        if hidden { hidden = false }
    }
}
