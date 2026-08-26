import Foundation
#if canImport(UserNotifications)
    import UserNotifications
#endif

/// **W-FOCUS-FILTER (v0.15.2)** — the pure suppression decision for the
/// HealthLog Focus filter.
///
/// This is the single, safety-critical place that decides whether a *local*
/// notification we are about to schedule should be **held back** because a
/// HealthLog Focus filter is active with suppress-on.
///
/// **Safety invariant (NEVER suppress urgent health).** A notification whose
/// interruption level is `.critical` or `.timeSensitive` is *always* delivered,
/// regardless of the focus filter. The critical-med AlarmKit path
/// (`AppContainer+CriticalAlarmScheduler`) does not flow through this gate at
/// all, and an urgent illness `SYSTEM_ALERT` rides `.timeSensitive`/`.critical`,
/// so both are exempt by construction. The gate only ever holds back *routine*
/// reminders — `.active` / `.passive` med-backups, mood, preventive-care, and
/// low-supply heads-ups — which are not health-urgent.
///
/// **Delivery-only, never data-loss.** A held-back reminder is simply not
/// `add()`-ed to `UNUserNotificationCenter`; the underlying schedule (the
/// server-side reminder cron, the medication intake ledger, the reminder rows)
/// is untouched. When the Focus turns off, the next scheduling sweep re-offers
/// the reminder, and the user can still mark the intake/reminder later. We hold
/// back *banners*, not data.
enum FocusFilterSuppression {
    /// Urgency classes a routine-vs-urgent decision keys on. Kept as a small
    /// enum so the core decision is unit-testable without constructing a real
    /// `UNNotificationContent`.
    enum Urgency: Equatable {
        /// `.critical` / `.timeSensitive` — a health-urgent alert. NEVER held back.
        case urgent
        /// `.active` / `.passive` — a routine reminder. Held back when the filter
        /// is active with suppress-on.
        case routine
    }

    /// The pure decision: given the active config + a notification's urgency,
    /// should we hold the banner back?
    ///
    /// - The urgent class is **never** held back — the safety invariant.
    /// - The routine class is held back **iff** the config currently suppresses
    ///   routine reminders (filter active + suppress-on).
    static func shouldSuppress(config: FocusFilterConfig, urgency: Urgency) -> Bool {
        switch urgency {
        case .urgent:
            // Safety invariant: urgent health escalations always come through.
            false
        case .routine:
            config.suppressesRoutineReminders
        }
    }

    #if canImport(UserNotifications)
        /// Map a notification's interruption level to an ``Urgency`` class.
        /// `.critical` + `.timeSensitive` are urgent; `.active` + `.passive`
        /// (and any future unknown level, treated conservatively as routine —
        /// an unknown level must never *gain* exemption) are routine.
        static func urgency(for level: UNNotificationInterruptionLevel) -> Urgency {
            switch level {
            case .critical, .timeSensitive:
                return .urgent
            case .active, .passive:
                return .routine
            @unknown default:
                return .routine
            }
        }

        /// Convenience: should this concrete request be held back under the
        /// current shared config? Used by the central `add()` seam.
        @MainActor
        static func shouldSuppress(
            request: UNNotificationRequest,
            config: FocusFilterConfig = FocusFilterConfigStore.current()
        ) -> Bool {
            let urgency = urgency(for: request.content.interruptionLevel)
            return shouldSuppress(config: config, urgency: urgency)
        }
    #endif
}
