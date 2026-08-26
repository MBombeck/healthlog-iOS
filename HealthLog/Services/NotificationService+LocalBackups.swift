import Foundation
#if canImport(UserNotifications)
    import UserNotifications
#endif
#if canImport(UIKit)
    import UIKit
#endif

#if canImport(UserNotifications) && canImport(UIKit)

    /// v0.5.4.3 HP5 — local-fallback scheduling for medication reminders.
    ///
    /// **Background:** the server's APNs cron is the primary delivery
    /// mechanism for `MEDICATION_REMINDER` pushes. But APNs is not a
    /// hard guarantee — if the device is offline at the moment the cron
    /// runs, or the user has notification grouping deferring delivery,
    /// the banner may not surface at the exact scheduled time.
    ///
    /// This extension adds an opt-in batch scheduler: callers hand over
    /// the list of upcoming `MedicationIntake` schedule stamps and we
    /// schedule local `UNTimeIntervalNotificationTrigger` requests as
    /// a *backup* layer. Each backup uses a deterministic identifier
    /// shape:
    ///
    ///     "med-local-backup-\(medicationId)-\(intakeId)"
    ///
    /// so the server-side APNs push (which carries the same identifier
    /// in `apns-collapse-id`) coalesces with the local one — iOS
    /// surfaces only one banner per scheduled intake.
    ///
    /// Schedules are skipped for stamps already in the past (`scheduledAt
    /// <= .now`) and stamps that already resolved (`status != .pending`).
    /// We also call `removePendingNotificationRequests(withIdentifiers:)`
    /// for every identifier we are about to replace, so a re-sync after
    /// the user marked an intake as taken cancels the orphaned backup.
    extension NotificationService {
        /// Schedule local-fallback reminders for the given list of
        /// pending medication intakes. Returns the count of scheduled
        /// requests for observability — the caller may log the number
        /// or surface it in a diagnostic card.
        ///
        /// - Parameter intakes: Today's pending intakes (typically the
        ///   `MedicationsStore.todayIntakes` array).
        /// - Parameter now: Injection seam — defaults to `.now`. Tests
        ///   pass a fixed instant so the "past stamps are skipped"
        ///   branch is exercisable deterministically.
        /// - Returns: Number of `UNNotificationRequest` instances that
        ///   were submitted to the user-notification center.
        @discardableResult
        func scheduleLocalBackups(
            for intakes: [MedicationIntake],
            now: Date = .now
        ) async -> Int {
            // Cancel every backup identifier we are about to (re-)schedule.
            // The center retains pending requests across launches, so
            // a stale entry from a prior schedule (e.g. user changed the
            // medication's schedule on the server) would otherwise live
            // until its trigger fires.
            let allIdentifiers = intakes.map { Self.localBackupIdentifier(for: $0) }
            UNUserNotificationCenter.current().removePendingNotificationRequests(
                withIdentifiers: allIdentifiers
            )

            var scheduled = 0
            for intake in intakes {
                guard let req = Self.buildLocalBackupRequest(for: intake, now: now) else {
                    continue
                }
                do {
                    // W-FOCUS-FILTER — gate routine med-backup banners behind a
                    // HealthLog Focus filter. A held-back backup is NOT counted
                    // (it was not delivered); the intake ledger is untouched, so
                    // the next post-Focus sweep re-offers it.
                    let added = try await addLocalNotification(req)
                    if added { scheduled &+= 1 }
                } catch {
                    HLLog.notifications.error(
                        "scheduleLocalBackups: add() failed for id=\(req.identifier, privacy: .public) err=\(LogSanitizer.redact(String(describing: error)), privacy: .public)"
                    )
                }
            }
            HLLog.notifications.info(
                "scheduleLocalBackups: \(scheduled) backup(s) scheduled out of \(intakes.count) intake(s)"
            )
            return scheduled
        }

        /// Pure builder for one local-backup request. Returns `nil` when
        /// the intake is non-pending or already past, so `scheduleLocal\
        /// Backups` can iterate without re-implementing the skip rules
        /// and tests can assert on each branch deterministically.
        ///
        /// Exposed at internal scope so the holistic-tests file can
        /// inspect the produced content + trigger without depending on
        /// `UNUserNotificationCenter.pendingNotificationRequests()`
        /// (which is flaky in host-app-less test runners).
        static func buildLocalBackupRequest(
            for intake: MedicationIntake,
            now: Date
        ) -> UNNotificationRequest? {
            guard intake.status == .pending else { return nil }
            guard intake.scheduledAt > now else { return nil }

            let content = UNMutableNotificationContent()
            content.title = String(localized: "Medication")
            content.body = String(localized: "Reminder — please take your medication.")
            content.sound = .default
            content.categoryIdentifier = Self.categoryMedication
            // userInfo carries the same shape an APNs payload would, so
            // a tap on the local-fallback banner hits the same action-
            // dispatch path as a real push (medicationId present →
            // med.taken / med.skipped server roundtrip).
            content.userInfo = [
                "medicationId": intake.medicationId,
                "scheduleId": intake.id,
                "scheduledFor": Self.iso8601(intake.scheduledAt),
                "eventType": Self.categoryMedication,
                // Marker so observability can distinguish local-backup
                // banners from "real" APNs banners. Tests assert on this
                // key.
                "localBackup": true
            ]

            let interval = intake.scheduledAt.timeIntervalSince(now)
            let trigger = UNTimeIntervalNotificationTrigger(
                timeInterval: max(1, interval),
                repeats: false
            )
            let id = Self.localBackupIdentifier(for: intake)
            return UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        }

        /// Stable identifier shape for the local-backup banner. Server's
        /// APNs sender carries the same string in `apns-collapse-id` so
        /// iOS coalesces the local-fallback into the server push when
        /// both land on-device. Tests pin the shape so a future rename
        /// can't silently break coalescing.
        static func localBackupIdentifier(for intake: MedicationIntake) -> String {
            "med-local-backup-\(intake.medicationId)-\(intake.id)"
        }

        /// v0.6.0.7 Spezi Phase E — one-shot purge of legacy
        /// `med-local-backup-*` pending notification requests. The
        /// legacy `MedicationReminderScheduler` orchestrator was never
        /// wired into the live `AppContainer`, so in practice the
        /// pending queue should already be empty — but defensive
        /// cleanup catches any TestFlight build that did surface these
        /// requests through ad-hoc test paths, plus future-proofs us
        /// against a possible local-backup id leaking back in via the
        /// `NotificationService+LocalBackups` builder which stays
        /// available for test callers.
        ///
        /// The Spezi-driven path uses a different identifier shape
        /// (`edu.stanford.spezi.scheduler.notification.event.<task-
        /// id>.<startInterval>`), so it does NOT match this prefix.
        ///
        /// Gated by a `UserDefaults` flag so the sweep runs exactly
        /// once per device + install. Idempotent on the off chance
        /// the flag is wiped: the second invocation finds no matching
        /// pending requests and is a no-op.
        static let legacyLocalBackupPurgeDefaultsKey = "spezi.phaseE.legacy-local-backup-purge-v1"

        static func purgeLegacyLocalBackupsIfNeeded(
            defaults: UserDefaults = .standard
        ) async {
            guard !defaults.bool(forKey: legacyLocalBackupPurgeDefaultsKey) else { return }
            let center = UNUserNotificationCenter.current()
            let pending = await center.pendingNotificationRequests()
            let legacyIDs = pending
                .map(\.identifier)
                .filter { $0.hasPrefix("med-local-backup-") }
            if !legacyIDs.isEmpty {
                center.removePendingNotificationRequests(withIdentifiers: legacyIDs)
                HLLog.notifications.info(
                    "purgeLegacyLocalBackupsIfNeeded: removed \(legacyIDs.count) stale request(s)"
                )
            }
            defaults.set(true, forKey: legacyLocalBackupPurgeDefaultsKey)
        }

        /// ISO-8601 with fractional seconds — mirrors what the server's
        /// APNs payload uses. Private here because `iso8601String` on
        /// the main file is also private + we don't want to widen its
        /// visibility just for the test seam.
        private static func iso8601(_ date: Date) -> String {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f.string(from: date)
        }
    }

#endif
