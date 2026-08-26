import SwiftUI

// MARK: - Motion tokens (reduce-motion-aware via .hlAnimation)

public enum HLMotion {
    /// Standard spring for state transitions (~0.3s, ~0.78 damping — within
    /// the STANDARDS §6 200–300ms felt-budget).
    public static let spring = Animation.spring(response: 0.3, dampingFraction: 0.78)
    /// Snappy bounce for affordance feedback (selection, tap-reactions).
    public static let snap = Animation.snappy(duration: 0.22, extraBounce: 0.05)
    /// Smooth easeInOut for opacity / scale crossfades.
    public static let smooth = Animation.easeInOut(duration: 0.18)
    /// Raw progress-fill tween duration (seconds). Exposed as a plain `Double`
    /// because SwiftUI's `Animation` value is opaque and can't be introspected
    /// for its duration in a unit test — the `progress` token below is built
    /// from this constant so `HLMotionTests` can lock it inside the doctrine.
    public static let progressDuration: TimeInterval = 0.28

    /// Gentle tween for progress fills (ring overlays etc.).
    ///
    /// v0.12 W3-6 — pulled from `0.6s` to `0.28s`. The prior 0.6s was 2× the
    /// 200–300 ms perceptual doctrine ceiling and 2× what `HLRing` itself now
    /// uses for its sweep (`.easeOut(0.28)`); a progress fill that lags the
    /// ring it lives beside reads as sluggish. 0.28s lands inside the budget
    /// and matches the ring tempo. Consumers (`AchievementDetailSheet`) are
    /// already reduce-motion-gated via `.hlAnimation` / `reduceMotion ? nil`.
    public static let progress = Animation.easeOut(duration: progressDuration)
    /// Hero parallax rate — hero translates UPWARD at 1.3x scroll velocity
    /// while remaining content tracks 1:1 with the user's finger. Calibrated
    /// against Apple Health's metric-detail hero parallax. Reduce-motion
    /// callers MUST bypass this multiplier and pin to `1.0` (no parallax).
    /// W-IMPL-MOTION-POLISH (v0.5.5.1).
    public static let parallaxRate: CGFloat = 1.3
    /// Greeting fade distance — total scroll points over which the greeting
    /// dampens from 1.0 → `parallaxFadeFloor` opacity. 80pt matches the
    /// hero-strip's first-screen breathing budget on iPhone 17 Pro.
    public static let parallaxFadeDistance: CGFloat = 80
    /// Lower-bound opacity for the greeting once `parallaxFadeDistance`
    /// scroll has elapsed. Stops short of zero so the text is still legible
    /// during fast flicks back to the top.
    public static let parallaxFadeFloor: Double = 0.6
}

// MARK: - Opacity tokens

public enum HLOpacity {
    /// Weak tinted surface (statusBad-backed warning fills etc.).
    public static let surfaceTintWeak: Double = 0.08
    /// Default tinted surface (HLBadge background, status pill bg).
    public static let surfaceTintStrong: Double = 0.18
    /// Disabled control alpha (per HIG button disabled treatment).
    public static let disabled: Double = 0.5
    /// Locked / dimmed cell content (achievements locked state).
    public static let locked: Double = 0.7
}
