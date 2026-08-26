import Foundation
#if canImport(UserNotifications)
    import UserNotifications
#endif
#if canImport(UIKit)
    import UIKit
#endif

#if canImport(UserNotifications) && canImport(UIKit)

    /// **W-THRESHOLD-NUDGE (v0.15.2) — the local-notification delivery for the
    /// calm, MDR-safe out-of-range nudge.**
    ///
    /// The pure decision lives in ``ThresholdNudgeEvaluator``; this extension
    /// only *delivers* an already-decided ``ThresholdNudgeContent`` as a local
    /// banner. Two safety properties are wired here by construction:
    ///
    /// 1. **Never urgent.** The content is fired at `.passive` (or `.active` at
    ///    most) — NEVER `.timeSensitive` / `.critical`. An out-of-range reading
    ///    is informational, not an emergency, and an emergency level would be an
    ///    App-Review / MDR concern. The builder hard-codes `.passive`.
    /// 2. **Suppressible by the Focus filter.** It funnels through
    ///    ``addLocalNotification`` like every routine reminder, so a HealthLog
    ///    Focus filter holds it back (it is classified routine, not urgent).
    @MainActor
    extension NotificationService {
        /// Stable identifier prefix so a re-fired nudge for the same breach key
        /// replaces (rather than stacks) the pending banner.
        nonisolated static let thresholdNudgeIdentifierPrefix = "threshold-nudge."

        /// Deliver a decided out-of-range nudge as a local banner. Returns
        /// `true` when the banner was added, `false` when the Focus filter held
        /// it back. Never throws past a scheduling hiccup — a nudge failing to
        /// arm must not break the measurement-log path that triggered it.
        @discardableResult
        func scheduleThresholdNudge(
            _ content: ThresholdNudgeContent,
            breachKey: String,
            center: UNUserNotificationCenter = .current()
        ) async -> Bool {
            // Respect notification authorization — an unauthorized add silently
            // drops, so skip rather than pretend it delivered.
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional else
            {
                return false
            }

            let request = Self.buildThresholdNudgeRequest(content, breachKey: breachKey)
            do {
                // W-FOCUS-FILTER — routine `.passive` reminder: a HealthLog Focus
                // filter holds it back. Returns false when suppressed.
                return try await addLocalNotification(request, center: center)
            } catch {
                HLLog.notifications.error(
                    "threshold-nudge scheduling failed err=\(LogSanitizer.redact(String(describing: error)), privacy: .public)"
                )
                return false
            }
        }

        /// Pure builder for the out-of-range nudge request — exposed at internal
        /// scope so tests can pin the contract (the `.passive` level, the
        /// informational category, the deep-link userInfo) without
        /// `UNUserNotificationCenter` authorization.
        ///
        /// Fires immediately (a 1s time-interval trigger) — it is a retrospective
        /// reflection of the reading the user JUST logged, so there is no future
        /// schedule to compute.
        nonisolated static func buildThresholdNudgeRequest(
            _ content: ThresholdNudgeContent,
            breachKey: String
        ) -> UNNotificationRequest {
            let notification = UNMutableNotificationContent()
            notification.title = content.title
            notification.body = content.body
            // Deliberately silent (no sound) + `.passive`: this is an
            // informational, retrospective reflection — never an alarm. The
            // Focus filter classifies `.passive` as routine and may hold it back.
            notification.interruptionLevel = .passive
            notification.categoryIdentifier = Self.categoryThresholdNudge
            var userInfo: [String: String] = ["eventType": Self.categoryThresholdNudge]
            if let deepLink = content.deepLink {
                userInfo["deepLink"] = deepLink.absoluteString
            }
            notification.userInfo = userInfo

            // 1s trigger so it surfaces right after the log without blocking the
            // write path. A unique-per-breach identifier replaces a pending
            // duplicate for the same standing condition.
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
            return UNNotificationRequest(
                identifier: Self.thresholdNudgeIdentifierPrefix + breachKey,
                content: notification,
                trigger: trigger
            )
        }
    }

#endif
