import Foundation
#if canImport(UserNotifications)
    import UserNotifications
#endif

#if canImport(UserNotifications) && canImport(UIKit)

    /// The payload a tapped medication banner acts on. Moved out of
    /// `NotificationService+Handler.swift` unchanged (file length).
    @MainActor
    extension NotificationService {
        /// Canonical `userInfo` shape for a medication-reminder banner —
        /// mirrors the server APNs payload contract so the on-tap action
        /// handler (`dispatchAction`) drives `med.taken` / `med.skipped` /
        /// `med.snooze.15m` regardless of whether the banner originated
        /// from the server cron, the local fallback, or the smart-reminder
        /// wrapper.
        /// Parse a banner's userInfo into the action payload, resolving
        /// `scheduledFor` for Spezi-built medication banners.
        ///
        /// SpeziScheduler materialises its `UNNotificationRequest`s at reconcile
        /// time and the `SchedulerNotificationsConstraint` hook only sees task +
        /// content, never the trigger — so the `scheduledFor` stamped there
        /// (`HealthLogStandard.notificationContent(for:content:)`) is the BUILD
        /// instant, not the fire instant. Acting on it would post "taken" against
        /// yesterday's reconcile time and miss today's slot. Those banners carry
        /// `speziScheduled: true`; for them the delivery date IS the slot (Spezi
        /// fires at the occurrence start), so we substitute it. Server pushes
        /// carry the real slot and are left untouched.
        nonisolated static func resolvedPayload(
            userInfo: [AnyHashable: Any],
            deliveredAt: Date
        ) -> APNsPayload? {
            guard let parsed = APNsPayload.parse(userInfo: userInfo) else { return nil }
            guard userInfo["speziScheduled"] as? Bool == true else { return parsed }
            return APNsPayload(
                title: parsed.title,
                body: parsed.body,
                eventType: parsed.eventType,
                metricType: parsed.metricType,
                deepLink: parsed.deepLink,
                isContentAvailable: parsed.isContentAvailable,
                medicationId: parsed.medicationId,
                scheduleId: parsed.scheduleId,
                scheduledFor: deliveredAt,
                reminderId: parsed.reminderId
            )
        }

        static func medicationUserInfo(
            medicationId: String,
            scheduleId: String?,
            scheduledFor: Date
        ) -> [String: Any] {
            var info: [String: Any] = [
                "medicationId": medicationId,
                "scheduledFor": iso8601String(from: scheduledFor),
                "eventType": categoryMedication
            ]
            if let scheduleId {
                info["scheduleId"] = scheduleId
            }
            return info
        }
    }

#endif
