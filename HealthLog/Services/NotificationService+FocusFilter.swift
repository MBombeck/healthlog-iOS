import Foundation
#if canImport(UserNotifications)
    import UserNotifications
#endif
#if canImport(UIKit)
    import UIKit
#endif

#if canImport(UserNotifications) && canImport(UIKit)

    /// **W-FOCUS-FILTER (v0.15.2)** — the central gated `add()` seam every
    /// *local* notification scheduling path funnels through, plus the
    /// observability log.
    ///
    /// Routing every local `add()` here gives the Focus filter exactly one
    /// chokepoint: a routine reminder built with `.active` / `.passive`
    /// interruption level is **held back** while a HealthLog Focus filter is
    /// active with suppress-on, while an urgent `.timeSensitive` / `.critical`
    /// banner is always delivered (the safety invariant lives in
    /// ``FocusFilterSuppression``). The held-back banner is simply not added —
    /// the underlying server cron / intake ledger / reminder rows are untouched,
    /// so nothing is lost; the next post-Focus sweep re-offers it.
    @MainActor
    extension NotificationService {
        /// iOS hard-caps the number of *pending* local notification requests an
        /// app may hold at 64; past that the system silently drops the oldest
        /// pending request. SpeziScheduler self-throttles against this limit for
        /// the requests IT owns, but the app's own ad-hoc local adds (mood
        /// reminder, per-med low-supply alerts, threshold nudges, snoozes,
        /// measurement reminders) are scheduled on TOP of that — un-budgeted,
        /// they can push the global total past 64 and silently evict a queued
        /// med reminder. BH-final-diff M1 — gate every ad-hoc add on the
        /// remaining headroom so the app's own requests never overflow the cap.
        static let pendingLocalNotificationCap = 64

        /// Add a *local* notification request through the Focus-filter gate.
        ///
        /// - When the active config holds back routine reminders and the request
        ///   is routine (`.active` / `.passive`), the `add()` is skipped and the
        ///   method returns `false` (held back).
        /// - When adding the request would exceed the iOS 64-pending cap, the
        ///   `add()` is skipped and the method returns `false` (budget exhausted),
        ///   so the app's own adds can never silently evict an already-queued
        ///   reminder (BH-final-diff M1).
        /// - Urgent requests (`.timeSensitive` / `.critical`) and every request
        ///   when no filter is active are added normally and return `true`.
        ///
        /// Throws only what `UNUserNotificationCenter.add` throws — a held-back
        /// or budget-skipped request never throws (it is a deliberate no-op
        /// delivery; the next sweep re-offers it once headroom frees up).
        @discardableResult
        func addLocalNotification(
            _ request: UNNotificationRequest,
            center: UNUserNotificationCenter = .current(),
            config: FocusFilterConfig = FocusFilterConfigStore.current()
        ) async throws -> Bool {
            if FocusFilterSuppression.shouldSuppress(request: request, config: config) {
                // Held back by the Focus filter — delivery only, no data touched.
                // No identifier in the message: a med-backup id embeds the
                // medicationId, so we log only the routine-suppression fact.
                HLLog.notifications.info("Focus filter held back a routine reminder")
                return false
            }
            // BH-final-diff M1 — central pending-budget accounting. Re-adding an
            // id that is ALREADY pending replaces it in place (no net growth), so
            // only gate when this id would be a NEW pending entry pushing the
            // total past the cap.
            let pending = await center.pendingNotificationRequests()
            let isReplacement = pending.contains { $0.identifier == request.identifier }
            if !isReplacement, pending.count >= Self.pendingLocalNotificationCap {
                HLLog.notifications
                    .warning(
                        "Pending notification budget exhausted (\(pending.count, privacy: .public)/\(Self.pendingLocalNotificationCap, privacy: .public)) — local add skipped, will re-offer next sweep"
                    )
                return false
            }
            try await center.add(request)
            return true
        }
    }

#endif
