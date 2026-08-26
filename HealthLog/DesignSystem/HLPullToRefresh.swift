import SwiftUI
#if canImport(UIKit)
    import UIKit
#endif

/// W-B184 — the **canonical WHOOP-style pull-to-refresh** for `ScrollView`-based
/// screens. This REPLACES stock `.refreshable` on the flagship scroll screens:
/// where the system control only exposes its un-stylable spinner, this primitive
/// owns the overscroll gesture and paints HealthLog's own monochrome story —
///
///   1. **Pull** (`progress` 0→1): a chevron glyph rotates/scales as the user
///      drags the content below its rest origin. Past the trigger threshold the
///      glyph "arms" (fills) — the visual promise that releasing now refreshes.
///   2. **Refresh** (released past threshold): the async `action` runs; the
///      glyph swaps to a mini `ProgressView`.
///   3. **Confirmation** (`SyncStateStore.phase == .done`): the spinner snaps to
///      `checkmark.circle.fill` — the same glyph language as `HLSyncBanner` —
///      with a `.symbolEffect(.bounce)` beat + ONE success haptic. It decays
///      with the store's existing `.done` hold (~1.5 s), no second state machine.
///
/// **Why reuse `SyncStateStore.phase`?** The flagship screens' `action` already
/// runs `syncStateStore.handshake()`, which walks `.syncing → .done (1.5 s) →
/// .idle`. The checkmark is therefore driven by the *same* server-truth phase
/// the bottom `SyncStatusCaption` reads — they can never disagree, and there is
/// exactly one phase machine in the app.
///
/// **Reduce-motion contract:** with `accessibilityReduceMotion` the pull glyph
/// neither rotates nor scales (opacity-only reveal), the checkmark bounce is
/// suppressed (hard cut glyph→checkmark), and every state swap is instantaneous.
/// All animated paths stay inside the 200–300 ms perceptual budget.
///
/// **Scope:** `ScrollView`-only. `List`/`Form` screens keep stock `.refreshable`
/// (an offset overlay is fragile over `List`'s recycling). See the rollout note
/// in the W-B184 report for the converted-vs-left screen split.
///
/// **Usage:**
/// ```swift
/// ScrollView { … }
///     .hlPullToRefresh {
///         await store.refresh(force: true)
///         await syncStateStore.handshake()
///     }
/// ```
struct HLPullToRefreshModifier: ViewModifier {
    /// The async refresh — the SAME work the replaced `.refreshable` ran.
    let action: @MainActor () async -> Void

    @Environment(SyncStateStore.self) private var syncState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Live overscroll in points: negative when the user pulls the content DOWN
    /// past its rest origin (the inverse sign of the scrolled-up offset). 0 at
    /// rest. Written from `onScrollGeometryChange`'s action closure so the host
    /// body holds no per-frame Observation dependency.
    @State private var pullDistance: CGFloat = 0
    /// `true` while the async `action` is in flight (spinner state).
    @State private var isRefreshing = false
    /// Latches the `.done` confirmation so the checkmark survives the brief
    /// window between `action` returning and the phase decaying to `.idle`,
    /// and is shown exactly once per refresh.
    @State private var showsConfirmation = false
    /// Guards against re-triggering while a finger stays past threshold.
    @State private var didArmThisDrag = false

    /// Points of pull past which a release triggers a refresh (WHOOP-ish: a
    /// deliberate, full-thumb drag — not a flick).
    private let triggerThreshold: CGFloat = 88
    /// The glyph track height — the overlay occupies this band above the content.
    private let indicatorHeight: CGFloat = 64

    /// Normalized pull progress 0→1 against the trigger threshold.
    private var progress: CGFloat {
        guard triggerThreshold > 0 else { return 0 }
        return min(1, max(0, pullDistance / triggerThreshold))
    }

    /// `true` once the drag has crossed the threshold (glyph fills / arms).
    private var isArmed: Bool {
        pullDistance >= triggerThreshold
    }

    func body(content: Content) -> some View {
        content
            // Native iOS-18 scroll-geometry stream. `contentOffset.y +
            // contentInsets.top` is 0 at rest, positive scrolled UP, and
            // NEGATIVE when overscrolled DOWN (the pull). We negate it so
            // `pullDistance` reads as a positive pull magnitude.
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                -(geometry.contentOffset.y + geometry.contentInsets.top)
            } action: { _, newValue in
                handlePull(newValue)
            }
            .overlay(alignment: .top) {
                indicator
            }
            .onChange(of: syncState.phase) { _, newPhase in
                // The shared phase machine reached `.done` while OUR refresh was
                // in flight → arm the checkmark + fire the single success
                // haptic. The store decays `.done → .idle` after its hold; the
                // confirmation latch follows it.
                if newPhase == .done, isRefreshing || showsConfirmation {
                    confirmSuccess()
                } else if newPhase == .idle {
                    withMotion { showsConfirmation = false }
                }
            }
    }

    // MARK: - Gesture handling

    private func handlePull(_ distance: CGFloat) {
        pullDistance = distance

        // Release detection: the finger has lifted (offset relaxing back toward
        // 0) AFTER an armed drag → trigger the refresh once.
        if distance >= triggerThreshold {
            didArmThisDrag = true
        } else if didArmThisDrag, distance < triggerThreshold * 0.5,
                  !isRefreshing
        {
            didArmThisDrag = false
            triggerRefresh()
        }

        // A fresh pull from rest clears a lingering confirmation so the next
        // pull starts from the clean chevron state.
        if distance <= 0, showsConfirmation, !isRefreshing {
            showsConfirmation = false
        }
    }

    private func triggerRefresh() {
        guard !isRefreshing else { return }
        withMotion {
            isRefreshing = true
            showsConfirmation = false
        }
        Task { @MainActor in
            // Run the screen's refresh and the sync handshake CONCURRENTLY. The
            // handshake is what walks `SyncStateStore.phase → .done`, which is
            // the single trigger for the checkmark + bottom `SyncStatusCaption`
            // — driving it here means EVERY converted screen confirms with the
            // same "Haken", even the ones whose own `action` is a read-only
            // `store.load()`. There is still exactly one phase machine.
            async let refresh: Void = action()
            async let handshake: Void = syncState.handshake()
            _ = await (refresh, handshake)
            // The phase machine owns the `.done` confirmation; once it lands
            // `onChange(of: phase)` paints the checkmark. We always drop the
            // spinner here: on success the checkmark has already swapped in (the
            // phase reached `.done` during the awaits); on error the phase short-
            // circuited to `.idle` and there is no fake confirmation — clearing
            // the spinner returns the indicator to its resting chevron.
            withMotion { isRefreshing = false }
        }
    }

    private func confirmSuccess() {
        guard !showsConfirmation else { return }
        withMotion {
            isRefreshing = false
            showsConfirmation = true
        }
        fireSuccessHaptic()
    }

    private func fireSuccessHaptic() {
        #if canImport(UIKit)
            // ONE success notification — matches the WHOOP "Haken" confirmation
            // beat. `UINotificationFeedbackGenerator` self-respects the device's
            // per-app haptic + Reduce-Motion settings, so no manual gate needed.
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.success)
        #endif
    }

    private func withMotion(_ mutate: () -> Void) {
        if reduceMotion {
            withTransaction(Transaction(animation: nil), mutate)
        } else {
            withAnimation(HLMotion.snap, mutate)
        }
    }

    // MARK: - Indicator

    private var indicator: some View {
        ZStack {
            if showsConfirmation {
                confirmationGlyph
            } else if isRefreshing {
                ProgressView()
                    .controlSize(.regular)
                    .tint(HLText.secondary)
                    .transition(.opacity)
            } else if pullDistance > 1 {
                pullGlyph
                    .transition(.opacity)
            }
        }
        .frame(height: indicatorHeight)
        // Sit the band just above the content's first row, fading in with pull.
        .frame(maxWidth: .infinity)
        .offset(y: -indicatorHeight + min(pullDistance, indicatorHeight + 12))
        .accessibilityHidden(true) // the bottom SyncStatusCaption is the a11y voice
        .allowsHitTesting(false)
    }

    private var pullGlyph: some View {
        Image(systemName: "chevron.down")
            // swiftlint:disable:next dynamic_type_bypass
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(isArmed ? HLText.primary : HLText.tertiary)
            .opacity(reduceMotion ? progress : 1)
            // Reduce-motion: opacity-only reveal, no rotation/scale.
            .rotationEffect(reduceMotion ? .zero : .degrees(Double(progress) * 180))
            .scaleEffect(reduceMotion ? 1 : (0.7 + 0.3 * progress))
            .animation(reduceMotion ? nil : HLMotion.smooth, value: isArmed)
    }

    private var confirmationGlyph: some View {
        Image(systemName: "checkmark.circle.fill")
            // swiftlint:disable:next dynamic_type_bypass
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(HLText.primary)
            .symbolEffect(
                .bounce,
                options: reduceMotion ? .speed(1000) : .default,
                value: showsConfirmation
            )
            .transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
    }
}

extension View {
    /// Applies the canonical WHOOP-style pull-to-refresh (custom pull glyph +
    /// `.done`-driven checkmark + one success haptic). REPLACES `.refreshable`
    /// on `ScrollView`-based screens — do not mount both (double indicator).
    ///
    /// - Parameter action: the async refresh; pass the exact work the replaced
    ///   `.refreshable` ran (typically `store.refresh(force:)` +
    ///   `syncStateStore.handshake()`).
    func hlPullToRefresh(action: @escaping @MainActor () async -> Void) -> some View {
        modifier(HLPullToRefreshModifier(action: action))
    }
}
