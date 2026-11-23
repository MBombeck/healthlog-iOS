import Foundation
#if canImport(Spezi) && canImport(SpeziScheduler)
    @_spi(APISupport) import Spezi
    import SpeziScheduler
#endif

/// Silences the local reminder of a dose the server ledger already resolved.
///
/// A reminder was closed only by its own banner actions. A dose taken in the
/// app, on a widget, a control, the watch, through Siri or on the web left the
/// pending notification in place, so it fired anyway. SpeziScheduler skips
/// completed events when it re-plans its requests, so completing the event of
/// every slot the server reports as taken or skipped, and asking for a refresh,
/// removes exactly those reminders. Nothing here records or computes a dose:
/// the server's today list is the only input.
enum MedicationReminderCompletion {
    /// A slot the server reports as resolved.
    struct ResolvedSlot: Hashable {
        let medicationId: String
        let scheduledAt: Date
    }

    /// An open reminder occurrence, reduced to what matching reads.
    struct ReminderEvent: Equatable {
        let index: Int
        let medicationId: String
        let start: Date
    }

    /// Covers the drift between the server's slot instant and the reminder's
    /// occurrence start. Small on purpose: two doses of one medication can lie
    /// half an hour apart, and each slot may silence only its own reminder.
    static let driftTolerance: TimeInterval = 5 * 60

    /// Taken or skipped slots in the server's today list.
    static func resolvedSlots(in intakes: [MedicationIntake]) -> [ResolvedSlot] {
        intakes
            .filter { $0.status == .taken || $0.status == .skipped }
            .map { ResolvedSlot(medicationId: $0.medicationId, scheduledAt: $0.scheduledAt) }
    }

    /// The events to complete: per slot at most one event of the same
    /// medication. Reminders fire in the device zone while slots live in the
    /// account zone, so after travel the same dose reads "08:00" in both but
    /// lies hours apart; that wall-clock match wins over the instant match.
    static func eventsToComplete(
        events: [ReminderEvent],
        slots: [ResolvedSlot],
        deviceTimeZone: TimeZone,
        accountTimeZone: TimeZone
    ) -> [Int] {
        var taken = Set<Int>()
        for slot in slots {
            let candidates = events.filter { $0.medicationId == slot.medicationId && !taken.contains($0.index) }
            let byWallClock = candidates.first {
                sameWallClock($0.start, deviceTimeZone, slot.scheduledAt, accountTimeZone)
            }
            let byInstant = candidates
                .filter { abs($0.start.timeIntervalSince(slot.scheduledAt)) <= driftTolerance }
                .min { abs($0.start.timeIntervalSince(slot.scheduledAt)) < abs($1.start.timeIntervalSince(slot.scheduledAt)) }
            if let pick = byWallClock ?? byInstant {
                taken.insert(pick.index)
            }
        }
        return taken.sorted()
    }

    /// Whether an occurrence of `medicationId` starting at `start` is one of
    /// the resolved `slots`, by the same rule ``eventsToComplete`` uses: the
    /// same wall-clock time (occurrence in the device zone, slot in the account
    /// zone) or an instant within ``driftTolerance``. The critical alarms use
    /// it to suspend today's occurrence of a dose already taken (#188 (5)).
    static func occurrenceIsResolved(
        medicationId: String,
        start: Date,
        slots: [ResolvedSlot],
        deviceTimeZone: TimeZone,
        accountTimeZone: TimeZone
    ) -> Bool {
        slots.contains { slot in
            slot.medicationId == medicationId
                && (sameWallClock(start, deviceTimeZone, slot.scheduledAt, accountTimeZone)
                    || abs(start.timeIntervalSince(slot.scheduledAt)) <= driftTolerance)
        }
    }

    private static func sameWallClock(_ lhs: Date, _ lhsZone: TimeZone, _ rhs: Date, _ rhsZone: TimeZone) -> Bool {
        let units: Set<Calendar.Component> = [.year, .month, .day, .hour, .minute]
        var lhsCalendar = Calendar(identifier: .gregorian)
        lhsCalendar.timeZone = lhsZone
        var rhsCalendar = Calendar(identifier: .gregorian)
        rhsCalendar.timeZone = rhsZone
        return lhsCalendar.dateComponents(units, from: lhs) == rhsCalendar.dateComponents(units, from: rhs)
    }
}

#if canImport(Spezi) && canImport(SpeziScheduler)
    extension MedicationReminderCompletion {
        /// Completes the reminder events of `slots` and re-plans the pending
        /// notifications. Silent no-op before Spezi has booted.
        @MainActor
        static func completeReminders(
            for slots: [ResolvedSlot],
            deviceTimeZone: TimeZone = .current,
            accountTimeZone: TimeZone
        ) {
            guard !slots.isEmpty,
                  let spezi = SpeziAppDelegate.spezi,
                  let scheduler = spezi.module(Scheduler.self),
                  let earliest = slots.map(\.scheduledAt).min(),
                  let latest = slots.map(\.scheduledAt).max() else { return }
            // Wide enough for any zone offset between device and account.
            let margin: TimeInterval = 15 * 60 * 60
            do {
                let events = try scheduler.queryEvents(for: earliest.addingTimeInterval(-margin) ..< latest.addingTimeInterval(margin))
                let open: [ReminderEvent] = events.enumerated().compactMap { index, event in
                    guard !event.isCompleted,
                          let medicationId = MedicationsSchedulerModule.medicationId(fromTaskID: event.task.id) else { return nil }
                    return ReminderEvent(index: index, medicationId: medicationId, start: event.occurrence.start)
                }
                let picks = eventsToComplete(
                    events: open,
                    slots: slots,
                    deviceTimeZone: deviceTimeZone,
                    accountTimeZone: accountTimeZone
                )
                guard !picks.isEmpty else { return }
                for index in picks {
                    _ = try? events[index].complete(ignoreCompletionPolicy: true)
                }
                scheduler.manuallyScheduleNotificationRefresh()
                // A count only — operator-grade, no PII.
                // swiftlint:disable:next hllog_public_privacy_interpolation
                HLLog.notifications.info("Reminder completion: \(picks.count, privacy: .public) reminder(s) silenced")
            } catch {
                HLLog.notifications.error(
                    "Reminder completion: queryEvents failed err=\(LogSanitizer.redact(String(describing: error)), privacy: .public)"
                )
            }
        }
    }
#endif
