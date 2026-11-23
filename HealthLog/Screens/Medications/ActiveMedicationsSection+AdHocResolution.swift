import Foundation

extension ActiveMedicationsSection {
    /// **`scheduledFor` for an ad-hoc Genommen/Übersprungen tap.**
    ///
    /// When `resolveDispatchDose` finds no pending today-row, the tap falls
    /// through to the ad-hoc synth POST. A medication that doses today marks
    /// today's slot: the latest one already due, else the next one today
    /// (MED, #151: never yesterday's evening dose).
    ///
    /// **D3 #3 — a day without a slot books `now`.** This used to look back up
    /// to 60 days for the last due slot. On the Saturday before a Sunday
    /// GLP-1 dose the tap sent last Sunday 09:00 as `scheduledFor`, and the
    /// synth path clamped `takenAt` onto it: the server either answered
    /// "already taken" and stored nothing, or filled last week's slot with the
    /// wrong time. Sunday's slot stayed open, reminder and alarm came, and a
    /// second injection was a tap away. Without a slot today the tap now sends
    /// `now` for both, and the server binds the take by its time (a Saturday
    /// lies inside a weekly dose's band around Sunday).
    ///
    /// "Today" is the server's: `daySlots` are the open slots of today's
    /// `dose-history` (``MedicationsStore/daySlots(medicationId:day:)``, the
    /// read the intake form uses), so every cadence counts as the server
    /// counts it. Only when that read failed (`nil`) does the local engine
    /// decide, and only for today.
    ///
    /// `nonisolated static` so it shares the engine with `resolveDispatchDose`
    /// and the unit suite can drive it off the MainActor. Lives in its own file
    /// to keep `ActiveMedicationRow.swift` under the file-length budget.
    nonisolated static func resolveAdHocScheduledFor(
        medication: Medication,
        now: Date,
        timeZone: TimeZone = .current,
        daySlots: [IntakeSlotAttribution.DaySlot]? = nil
    ) -> Date {
        // PRN / no-schedule (asNeeded or empty entries): the act IS the slot.
        let entries = medication.schedule.entries
        guard !entries.isEmpty,
              entries.contains(where: { $0.cadence != .asNeeded }) else { return now }
        if let daySlots {
            let instants = daySlots.map(\.instant)
            return instants.filter { $0 <= now }.max() ?? instants.filter { $0 > now }.min() ?? now
        }
        let context = MedicationRecurrenceEngine.Context(
            medication: medication,
            timeZone: timeZone,
            now: now
        )
        return todaySlot(entries: entries, context: context, now: now, timeZone: timeZone) ?? now
    }

    /// Today's slot for an ad-hoc tap (profile day, DST-safe calendar bounds):
    /// the latest occurrence at or before `now`, else the first one after it.
    /// `nil` when the medication has no occurrence today.
    nonisolated static func todaySlot(
        entries: [ScheduleEntry],
        context: MedicationRecurrenceEngine.Context,
        now: Date,
        timeZone: TimeZone
    ) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let startOfToday = calendar.startOfDay(for: now)
        guard let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday) else { return nil }
        let today = entries.filter { $0.cadence != .asNeeded }.flatMap { entry in
            MedicationRecurrenceEngine.occurrences(
                in: startOfToday ... startOfTomorrow.addingTimeInterval(-1),
                entry: entry,
                context: context
            ).map(\.at)
        }
        return today.filter { $0 <= now }.max() ?? today.filter { $0 > now }.min()
    }
}
