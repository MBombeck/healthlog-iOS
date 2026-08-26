//
// v0.6.1.3 Y4.1 — App-Badge service.
//
// The Home-screen app icon now surfaces a numeric badge that reflects
// the medication doses still pending. The badge is a single
// authoritative number computed from `MedicationsStore.dueOrMissedCount`
// — we explicitly do NOT increment from per-notification deliveries
// because that would double-count (Spezi-scheduled banner + server APN
// for the same dose would each bump the badge). Instead, every event
// that mutates the due-count (foreground, mark, snooze, BG refresh,
// willPresent) re-reads the store and pushes the absolute number.
//
// Setter routes through iOS-16+ `UNUserNotificationCenter.setBadgeCount`
// rather than the deprecated `UIApplication.applicationIconBadgeNumber`
// — Apple is removing the legacy path in a future iOS release and the
// new API is the documented forward path.
//
#if canImport(UserNotifications) && canImport(UIKit)
    import Foundation
    import UserNotifications

    extension NotificationService {
        /// Pushes the supplied badge count to the system icon. Idempotent
        /// — iOS coalesces identical values. Failures route through a
        /// do/catch and surface via `HLLog.notifications.warning`; we do
        /// not re-throw because a setBadgeCount failure is "best effort"
        /// — the badge catches up on the next mutation event (foreground,
        /// mark, willPresent, BG refresh).
        ///
        /// The MainActor isolation matches the rest of
        /// `NotificationService` so callers don't need a hop, and so the
        /// next dispatch (from scenePhase, mark, willPresent) can chain
        /// the setter directly.
        @MainActor
        func setBadgeCount(_ count: Int) async {
            let clamped = max(0, count)
            do {
                try await UNUserNotificationCenter.current().setBadgeCount(clamped)
                HLLog.notifications.debug("Badge set to \(clamped)")
            } catch {
                HLLog.notifications.warning(
                    "setBadgeCount failed: \(LogSanitizer.redact(String(describing: error)), privacy: .public)"
                )
            }
        }

        /// Recompute the badge from a `MedicationsStore` snapshot. The
        /// store is the single source of truth — every recompute hook
        /// (foreground, mark, willPresent, BG refresh) calls this with
        /// the live store reference, so the badge can never drift from
        /// the in-app dose list.
        ///
        /// `MainActor`-isolated because `MedicationsStore` is too —
        /// reading `dueOrMissedCount` requires that hop already.
        @MainActor
        func refreshBadge(from store: MedicationsStore) async {
            await setBadgeCount(store.dueOrMissedCount())
        }

        /// LOGOUT-NOTIF — purge every notification surface on sign-out so PHI
        /// can't linger for the next user on a shared device. Clears:
        ///   - delivered notifications (a med reminder on the lock screen
        ///     reveals medication use),
        ///   - pending scheduled local requests (future med reminders), and
        ///   - the app-icon badge (its count reveals pending doses).
        ///
        /// Purely local — runs REGARDLESS of network (the cascade calls it
        /// unconditionally). Idempotent + safe when nothing is scheduled or
        /// delivered: the `removeAll*` APIs and `setBadgeCount(0)` are all
        /// no-ops on an empty state. The per-medication SpeziScheduler reminder
        /// bookkeeping is reconciled separately in
        /// `MedicationsStore.clearOnLogout()` (it purges every `med-*` task
        /// against the now-empty medication list), so its internal state stays
        /// consistent with this raw center wipe.
        @MainActor
        func clearAllNotificationsOnLogout() async {
            let center = UNUserNotificationCenter.current()
            center.removeAllDeliveredNotifications()
            center.removeAllPendingNotificationRequests()
            await setBadgeCount(0)
            HLLog.notifications.debug("Cleared delivered + pending notifications and badge on logout")
        }

        /// Drives the willPresent + dispatchAction recompute path. Wired
        /// from `AppContainer.init` to read the live MedicationsStore
        /// snapshot without an import cycle.
        ///
        /// Read inside `userNotificationCenter(_:willPresent:)` so a med
        /// reminder banner that arrives in the foreground immediately
        /// re-publishes the badge — the operator sees the new "due"
        /// count without having to put the app to background first.
        @MainActor
        func attachMedicationsStoreAccessor(_ accessor: @escaping @MainActor () -> MedicationsStore?) {
            medicationsStoreAccessor = accessor
        }

        @MainActor
        func refreshBadgeFromAttachedStoreIfAvailable() async {
            guard let accessor = medicationsStoreAccessor,
                  let store = accessor() else { return }
            await refreshBadge(from: store)
        }

        /// **v0.14.1 notifications-bug H2 — foreground mood-nudge suppression
        /// read.** Whether a mood entry already exists for today, via the wired
        /// `moodLoggedTodayAccessor`. `false` when unwired (headless tests /
        /// macOS) so a missing accessor never suppresses anything. Read from
        /// `userNotificationCenter(_:willPresent:)`.
        @MainActor
        func moodAlreadyLoggedToday() -> Bool {
            moodLoggedTodayAccessor?() ?? false
        }
    }
#endif
