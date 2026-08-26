import Foundation
#if canImport(UserNotifications)
    import UserNotifications
#endif

/// **MED-4 / AUDIT-PARITY C3** — once-per-crossing local low-supply alert guard.
///
/// The server cron is the authority for the cross-device low-supply push, but
/// the iOS app schedules a **local** alert too so a user who opened a med detail
/// and saw their stock fall below threshold gets notified even offline / before
/// the next cron run. The crossing must fire **once per crossing**, not on every
/// detail-screen open — this store remembers the last runway-day value we
/// alerted on for each medication, mirroring the server's "push once per
/// crossing" contract. UserDefaults is the right tier: a small, non-sensitive
/// de-dup ledger of "already warned at N days".
public enum LowSupplyAlertLedger {
    private static func key(_ medicationID: String) -> String {
        "hl.medication.lowSupplyAlertedAt.\(medicationID)"
    }

    /// The runway-day value we last fired an alert for this medication at, or
    /// `nil` when we never have.
    public static func lastAlertedDays(medicationID: String, defaults: UserDefaults = .standard) -> Int? {
        guard defaults.object(forKey: key(medicationID)) != nil else { return nil }
        return defaults.integer(forKey: key(medicationID))
    }

    /// Whether a fresh alert should fire for `runwayDays`. Fires when we have
    /// never alerted for this medication, OR when the supply RECOVERED above the
    /// last-alerted level and crossed back down (so re-stocking then depleting
    /// re-arms the alert). Does NOT re-fire while the runway keeps shrinking past
    /// an already-alerted value (avoids a daily nag as stock drains).
    public static func shouldAlert(
        medicationID: String,
        runwayDays: Int,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard let last = lastAlertedDays(medicationID: medicationID, defaults: defaults) else {
            return true
        }
        // Already alerted at or below this level → no re-nag while it drains.
        return runwayDays > last
    }

    /// Record that we alerted for this medication at `runwayDays`.
    public static func recordAlert(
        medicationID: String,
        runwayDays: Int,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(runwayDays, forKey: key(medicationID))
    }

    /// Clear the ledger for a medication (e.g. after a re-stock lifts the runway
    /// back above threshold) so the next crossing re-arms cleanly.
    public static func clear(medicationID: String, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key(medicationID))
    }
}

#if canImport(UserNotifications)

    extension NotificationService {
        /// Stable per-medication identifier so a re-evaluation replaces (rather
        /// than stacks) the pending low-supply request.
        nonisolated static func lowSupplyLocalIdentifier(medicationID: String) -> String {
            "low-supply-local.\(medicationID)"
        }

        /// **MED-4 / C3** — reconcile the local low-supply alert for one
        /// medication against its current server-stock-derived runway.
        ///
        /// - `medicationID`: the medication the supply belongs to.
        /// - `medicationName`: shown in the alert body.
        /// - `runwayDays`: the server-stock ÷ schedule projection (already
        ///   threshold-gated by the caller — `nil` means "above threshold / off"
        ///   and clears any pending alert + the ledger).
        ///
        /// Fires at most once per crossing (`LowSupplyAlertLedger`). When the
        /// runway recovers above threshold (`runwayDays == nil`) the ledger is
        /// cleared so a future depletion re-arms. Never throws — a scheduling
        /// hiccup must not break the detail-screen load path.
        @MainActor
        func reconcileLowSupplyAlert(
            medicationID: String,
            medicationName: String,
            runwayDays: Int?
        ) async {
            let center = UNUserNotificationCenter.current()
            let identifier = Self.lowSupplyLocalIdentifier(medicationID: medicationID)

            // Above threshold / alert off → clear any pending request + re-arm
            // the ledger for the next crossing.
            guard let runwayDays else {
                center.removePendingNotificationRequests(withIdentifiers: [identifier])
                LowSupplyAlertLedger.clear(medicationID: medicationID)
                return
            }

            // Once-per-crossing: skip if we already alerted at/below this level.
            guard LowSupplyAlertLedger.shouldAlert(medicationID: medicationID, runwayDays: runwayDays) else {
                return
            }

            // Respect notification authorization (a denied user would silently
            // drop the request — the connect banner already surfaces the ask).
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional else { return }

            let request = Self.buildLowSupplyRequest(
                medicationID: medicationID,
                medicationName: medicationName,
                runwayDays: runwayDays
            )
            do {
                center.removePendingNotificationRequests(withIdentifiers: [identifier])
                // W-FOCUS-FILTER — a supply heads-up is informational (`.active`),
                // so a HealthLog Focus filter holds it back. Record the alert only
                // when it was actually delivered, so the once-per-crossing ledger
                // re-offers it after the Focus ends.
                let delivered = try await addLocalNotification(request, center: center)
                guard delivered else { return }
                LowSupplyAlertLedger.recordAlert(medicationID: medicationID, runwayDays: runwayDays)
                // runwayDays is a small Int (operator-grade), medicationID is private.
                HLLog.notifications.info(
                    "low-supply-local armed medicationId=\(medicationID, privacy: .private) days=\(runwayDays, privacy: .public)"
                )
            } catch {
                HLLog.notifications.error(
                    "low-supply-local scheduling failed err=\(LogSanitizer.redact(String(describing: error)), privacy: .public)"
                )
            }
        }

        /// Pure builder for the local low-supply request — internal scope so
        /// tests can pin the trigger + routing contract without
        /// `UNUserNotificationCenter` authorization. Fires almost immediately
        /// (the crossing already happened); the body-tap routes to the
        /// medication's detail (where the supply tab lives) via the existing
        /// `medicationId` deep-link path.
        nonisolated static func buildLowSupplyRequest(
            medicationID: String,
            medicationName: String,
            runwayDays: Int
        ) -> UNNotificationRequest {
            let content = UNMutableNotificationContent()
            content.title = String(localized: "med.lowstock.push.title")
            content.body = String(
                format: String(localized: "med.lowstock.push.body"),
                medicationName,
                runwayDays
            )
            content.sound = .default
            // A supply heads-up is informational, not time-critical — keep it at
            // the default interruption level (the time-sensitive entitlement is
            // reserved for the medication *intake* reminders).
            content.interruptionLevel = .active
            // W-B185 — dedicated action-free category: a supply alert must NOT
            // carry the Taken/Snooze/Skipped intake actions (tapping "Taken"
            // would record a phantom dose). Body-tap still deep-links below.
            content.categoryIdentifier = Self.categoryMedicationLowStock
            // The receive side routes a body-tap via `medicationId` →
            // `healthlog://medications/<id>` (the detail screen hosts the supply
            // section). `eventType` is a distinct low-supply marker so it never
            // falls into the mood / intake-action branches. `deepLink` is the
            // explicit fallback if the id path is ever unavailable.
            content.userInfo = [
                "eventType": Self.eventTypeLowSupply,
                "medicationId": medicationID,
                "deepLink": "healthlog://medications/\(medicationID)"
            ]

            // Fire ~2 s out: the threshold crossing already occurred, this is a
            // near-immediate heads-up. A tiny delay keeps it off the main
            // scheduling tick.
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false)
            return UNNotificationRequest(
                identifier: lowSupplyLocalIdentifier(medicationID: medicationID),
                content: content,
                trigger: trigger
            )
        }

        /// Event-type marker on the low-supply push `userInfo` (distinct from
        /// `MEDICATION_REMINDER` so the body-tap default branch routes via
        /// `medicationId` without hitting the intake-action handlers).
        nonisolated static let eventTypeLowSupply = "MEDICATION_LOW_STOCK"
    }

#endif
