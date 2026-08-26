import SwiftUI

/// Shape-aware loading placeholder. Replaces the spinner-only first-paint
/// fallback (`ProgressView()` and one-off `RoundedRectangle.fill(HLColor.surface)`
/// blocks) with a single primitive that paints the silhouette of whatever
/// content is about to land — Apple Health, Withings, Mail and the system
/// Settings shimmer-placeholders all use this pattern so the screen never
/// "appears" out of an empty void.
///
/// **Shimmer:** a soft horizontal gradient sweeps across the placeholder
/// shape (`LinearGradient` masked by the configured silhouette). Animation
/// is 1.2s linear, repeating, **but** respects
/// `@Environment(\.accessibilityReduceMotion)` — when the user has
/// reduce-motion on, the sweep is swapped for a static mid-value fill so
/// nothing animates while the placeholder remains visually distinct from
/// the surrounding canvas. Colour conveys "loading" on its own; motion is
/// affordance, not signal.
///
/// **Base colour:** `HLSurface.tertiary` (recessed well) over the
/// secondary card backing. A narrow shimmer band on top lifts to
/// `HLText.primary.opacity(0.10)` to read as a passing highlight without
/// shouting over the rest of the card.
///
/// Accessibility:
/// - `accessibilityElement()` collapses children into one node.
/// - `accessibilityLabel` exposes the localized "Wird geladen" string.
/// - `accessibilityIdentifier("skeleton.<shape>")` so UI tests can lock
///   first-paint placement without inspecting pixel state.
public struct HLSkeleton: View {
    /// Silhouette the placeholder renders. `.rect` for text rows, `.capsule`
    /// for labels / chips, `.circle` for avatars + small icon affordances.
    public enum Shape: String {
        case rect
        case capsule
        case circle
    }

    private let shape: Shape
    private let width: CGFloat?
    private let height: CGFloat
    private let cornerRadius: CGFloat

    public init(
        _ shape: Shape = .rect,
        width: CGFloat? = nil,
        height: CGFloat = 16,
        cornerRadius: CGFloat = 8
    ) {
        self.shape = shape
        self.width = width
        self.height = height
        self.cornerRadius = cornerRadius
    }

    public var body: some View {
        SkeletonShimmer(
            shape: shape,
            cornerRadius: cornerRadius
        )
        .frame(width: width, height: shape == .circle ? (width ?? height) : height)
        .accessibilityElement()
        .accessibilityLabel(Text("Loading"))
        .accessibilityIdentifier("skeleton.\(shape.rawValue)")
    }
}

/// Internal shimmer renderer. Split out so the public `HLSkeleton` value
/// stays a thin parameter holder (testable without spinning up an animation
/// loop) and the motion-respecting state lives in one place.
private struct SkeletonShimmer: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let shape: HLSkeleton.Shape
    let cornerRadius: CGFloat

    @State private var phase: CGFloat = -1
    /// Drives the `.repeatForever` shimmer. Set `false` in `onDisappear`
    /// so the infinite repaint loop is torn down the moment the placeholder
    /// scrolls off-window or is replaced by loaded content — without this,
    /// every skeleton that ever appeared kept driving a 1.2s gradient sweep
    /// for the lifetime of the view tree (AUD-2 C1: 5-15 concurrent infinite
    /// loops contending with first-paint). Mirrors `HLCycleRing`'s pulse /
    /// sheen `onDisappear` cleanup.
    @State private var isAnimating = false

    var body: some View {
        // Base fill = recessed-well token (`HLSurface.tertiary`); shimmer
        // band lifts to `HLText.primary @ 10%` so it reads as a passing
        // highlight rather than a contrast cliff. When reduce-motion is
        // on, the band is replaced with a static mid-value overlay so the
        // placeholder still differentiates from a plain card-surface,
        // without any perceived "loading" cue lost (colour does the work).
        baseShape
            .overlay {
                if reduceMotion {
                    overlayBaseShape
                        .foregroundStyle(HLText.primary.opacity(0.05))
                } else {
                    LinearGradient(
                        gradient: Gradient(colors: [
                            .clear,
                            HLText.primary.opacity(0.10),
                            .clear
                        ]),
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .mask(overlayBaseShape)
                    .offset(x: phase * 200)
                }
            }
            .onAppear {
                guard !reduceMotion else { return }
                isAnimating = true
                withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
            .onDisappear {
                // Halt the `.repeatForever` sweep when the placeholder leaves
                // the view tree (scrolled off, or replaced by loaded content).
                // Re-issuing the offset inside a zero-duration animation cancels
                // the running repeating animation so it stops repainting; the
                // reset position keeps a re-appear (cell recycle) clean.
                guard isAnimating else { return }
                isAnimating = false
                withAnimation(.linear(duration: 0)) {
                    phase = -1
                }
            }
    }

    /// Filled silhouette used as the static base of the placeholder.
    @ViewBuilder
    private var baseShape: some View {
        switch shape {
        case .rect:
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(HLSurface.tertiary)
        case .capsule:
            Capsule(style: .continuous)
                .fill(HLSurface.tertiary)
        case .circle:
            Circle()
                .fill(HLSurface.tertiary)
        }
    }

    /// Same silhouette as `baseShape` but unfilled — drives the mask /
    /// reduce-motion overlay so the shimmer band stays clipped to the
    /// outline regardless of which `Shape` variant is in use.
    @ViewBuilder
    private var overlayBaseShape: some View {
        switch shape {
        case .rect:
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        case .capsule:
            Capsule(style: .continuous)
        case .circle:
            Circle()
        }
    }
}

#Preview("HLSkeleton — variants") {
    VStack(alignment: .leading, spacing: HLSpace.md) {
        HLCard {
            HStack(spacing: HLSpace.md) {
                HLSkeleton(.circle, width: 28, height: 28)
                VStack(alignment: .leading, spacing: HLSpace.xs) {
                    HLSkeleton(.capsule, width: 180, height: 16)
                    HLSkeleton(.capsule, width: 120, height: 12)
                }
                Spacer()
            }
        }
        HLCard {
            VStack(alignment: .leading, spacing: HLSpace.sm) {
                HLSkeleton(.capsule, width: 140, height: 18)
                HLSkeleton(.rect, height: 80, cornerRadius: 12)
            }
        }
    }
    .padding()
    .background(HLSurface.primary)
}
