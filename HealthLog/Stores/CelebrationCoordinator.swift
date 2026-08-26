import Foundation
import Observation

/// v0.5.5.6 RECONCILE-CELEBRATE — coordinates the `CelebrationOverlay`
/// presentation slot at the SwiftUI root.
///
/// Stores publish a new personal record by calling `celebrate(_:)`; the
/// `RootView` observes `current` and renders the existing
/// `CelebrationOverlay` (POLISH-PR) over `AuthenticatedShell` at the
/// highest z-index. The coordinator schedules an auto-dismiss after a
/// bounded TTL (default 4 s — matches the operator quote *"lass den
/// Moment wirken, aber halt ihn nicht fest"* with a small buffer over
/// the overlay's internal 2.5 s window) so a non-tapping user always
/// returns to a clean shell. Tapping the overlay (or the share button)
/// can call `dismiss()` to clear early.
///
/// **Single-slot.** Only one record is celebrated at a time; a fresh
/// `celebrate(_:)` replaces the previous slot and restarts the TTL.
/// Replacement is the right semantic: a back-to-back PR burst should
/// land on the latest record, not flash the older one halfway through.
///
/// **Why a coordinator (not a `@State` on the screen):** the celebration
/// must overlay any screen — the operator may be on Dashboard,
/// Measurements, Mood, even the picker sheet — when the commit lands.
/// Hosting the slot at the root (`RootView`) above the `TabView` ensures
/// the moment paints regardless of where the operator currently is.
///
/// **Singleton-style via DI.** Built once in `AppContainer`, injected
/// into `MeasurementsStore` (and any future store that detects a PR) +
/// the SwiftUI `RootView` via the standard `.environment(...)` channel.
@MainActor
@Observable
public final class CelebrationCoordinator {
    /// The record currently being celebrated. `nil` when no celebration
    /// is on screen. Observers (the root view) react to changes via
    /// SwiftUI's `@Observable` tracking.
    public private(set) var current: PersonalRecord?

    /// In-flight TTL countdown. Cancellation is the source of truth for
    /// "no auto-dismiss is scheduled"; we deliberately do NOT also
    /// track a boolean so the cancellation path stays the only
    /// invalidation rule. Mirrors `UndoCoordinator.expirationTask`.
    private var dismissTask: Task<Void, Never>?

    /// Default TTL — slightly longer than the overlay's internal
    /// 2.5 s self-dismiss so the slot stays populated for the entire
    /// confetti window plus a small buffer for the share-tap path. The
    /// overlay itself also fires `onDismiss` after 2.5 s; this fallback
    /// only matters when the overlay is replaced mid-animation or fails
    /// to invoke its callback (defensive coverage).
    public static let defaultTTL: TimeInterval = 4

    public init() {}

    /// Publish a new personal-record celebration. Cancels any
    /// pre-existing slot and starts a fresh TTL countdown.
    public func celebrate(_ record: PersonalRecord, ttl: TimeInterval = CelebrationCoordinator.defaultTTL) {
        dismissTask?.cancel()
        dismissTask = nil
        current = record
        scheduleDismissal(for: record.id, ttl: ttl)
    }

    /// Clear the slot immediately. Called by the overlay when the
    /// operator taps the dimming layer / share button. No-op when no
    /// celebration is on screen.
    public func dismiss() {
        guard current != nil else { return }
        dismissTask?.cancel()
        dismissTask = nil
        current = nil
    }

    // MARK: - Internals

    private func scheduleDismissal(for recordID: String, ttl: TimeInterval) {
        // Mirror `UndoCoordinator.scheduleExpiration`: nanoseconds-based
        // sleep so the value space stays compatible with `ttl: 0` tests
        // that want to assert "no auto-dismiss is ever scheduled".
        let nanos: UInt64 = ttl > 0 ? UInt64(ttl * 1_000_000_000) : 0
        dismissTask = Task { @MainActor [weak self] in
            if nanos > 0 {
                try? await Task.sleep(nanoseconds: nanos)
            }
            if Task.isCancelled { return }
            guard let self else { return }
            // Identity-check the record id — a replace that landed
            // between sleep end and this runloop pass would have set a
            // new `current`; we must not wipe it.
            guard current?.id == recordID else { return }
            current = nil
            dismissTask = nil
        }
    }
}
