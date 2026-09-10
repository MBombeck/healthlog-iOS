import Foundation

/// **Audit B-8 — the reminders follow the device into its new time zone.**
///
/// A medication reminder is projected with the zone that was current when it was
/// registered: `NotificationService+Registration` pins `comps.timeZone` into the
/// `UNCalendarNotificationTrigger`, and `MedicationsSchedulerModule` builds its
/// occurrences against a `MedicationRecurrenceEngine.Context` carrying the same
/// zone. That pinning is deliberate — it makes an already-scheduled fire instant
/// unambiguous — but it also means a device that crosses into another zone keeps
/// firing yesterday's wall-clock times until something re-registers them. Nothing
/// listened for the crossing, so "something" was whatever happened next: a
/// foreground load, a schedule edit, a background sync.
///
/// The store now listens. `NSSystemTimeZoneDidChange` runs the same reconcile
/// entry point every other trigger uses, so the pinned instants are re-projected
/// against the zone the user is actually in.
public extension MedicationsStore {
    /// Audit B-8 — observe `NSSystemTimeZoneDidChange` and reconcile the
    /// reminders once per genuine zone change.
    ///
    /// The system posts this notification for events that leave the resolved
    /// zone alone (a re-read of the same setting, a DST transition inside the
    /// same zone), and a reconcile rewrites every pending trigger — so the
    /// handler is debounced on the resolved zone identifier and a post that
    /// changes nothing costs nothing. The zone in effect when observation starts
    /// is the baseline: starting to observe never reconciles by itself.
    ///
    /// - Parameters:
    ///   - center: the notification centre to observe. Injectable so a test
    ///     drives its own centre instead of the process-wide default.
    ///   - currentTimeZone: resolves the zone now in effect. Injectable so a test
    ///     simulates travel without mutating the process default.
    /// - Returns: the observer token. The composition root discards it — the
    ///   store lives as long as the app does — but a caller that wants to stop
    ///   observing hands it back to `center.removeObserver(_:)`.
    @discardableResult
    func startObservingSystemTimeZoneChanges(
        center: NotificationCenter = .default,
        currentTimeZone: @escaping @Sendable @MainActor () -> TimeZone = { .current }
    ) -> any NSObjectProtocol {
        let memo = SystemTimeZoneMemo(currentTimeZone())
        return center.addObserver(
            forName: .NSSystemTimeZoneDidChange,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            let handle: @Sendable @MainActor () -> Void = {
                guard let store = self, memo.isChange(to: currentTimeZone()) else { return }
                store.reconcileSpeziSchedulerIfAvailable()
            }
            // The notification is delivered on whichever thread posted it. Stay
            // synchronous when that is already the main thread — the reconcile
            // then lands in the same run loop the change arrived in.
            if Thread.isMainThread {
                MainActor.assumeIsolated(handle)
            } else {
                _Concurrency.Task { @MainActor in handle() }
            }
        }
    }
}

/// Audit B-8 — the zone the last reminder reconcile ran for. Owned by the
/// observation closure (the notification centre retains it), so the store keeps
/// no stored state for a concern only the observer has.
@MainActor
private final class SystemTimeZoneMemo {
    private var zone: TimeZone

    init(_ zone: TimeZone) {
        self.zone = zone
    }

    /// `true` — and the memo advances — when `candidate` names a different zone
    /// than the one the last reconcile ran for. Compared on the identifier: two
    /// `TimeZone` values for the same IANA name are the same zone to a reminder.
    func isChange(to candidate: TimeZone) -> Bool {
        guard candidate.identifier != zone.identifier else { return false }
        zone = candidate
        return true
    }
}
