import Foundation

extension ActiveMedicationsSection {
    /// **v0.14.2 H3 — `scheduledFor` for an ad-hoc Genommen/Übersprungen tap.**
    ///
    /// When `resolveDispatchDose` finds no pending today-row, the tap falls
    /// through to the ad-hoc synth POST. The old path keyed that POST on
    /// `scheduledFor = .now`, which is correct for a **PRN** med but WRONG for a
    /// scheduled non-PRN med marked on a weekly off-day / cyclic off-week: the
    /// dose attaches to "now" instead of the real schedule slot → compliance
    /// mis-attribution. This resolves the nearest DUE slot from the canonical
    /// recurrence engine for scheduled meds (most-recent already-due occurrence
    /// in a ±window, else the soonest upcoming), and keeps `now` for PRN.
    ///
    /// `nonisolated static` so it shares the engine with `resolveDispatchDose`
    /// and the unit suite can drive it off the MainActor. Lives in its own file
    /// to keep `ActiveMedicationRow.swift` under the file-length budget.
    nonisolated static func resolveAdHocScheduledFor(
        medication: Medication,
        now: Date,
        timeZone: TimeZone = .current
    ) -> Date {
        // PRN / no-schedule (asNeeded or empty entries): the act IS the slot.
        let entries = medication.schedule.entries
        guard !entries.isEmpty,
              entries.contains(where: { $0.cadence != .asNeeded }) else { return now }

        let context = MedicationRecurrenceEngine.Context(
            medication: medication,
            timeZone: timeZone,
            now: now
        )
        // Look back up to 60 days for the most-recent already-due slot at/under
        // `now`; that is the dose the user is acting on. Falls forward to the
        // soonest upcoming occurrence only when nothing is yet due in the look-back.
        let lookbackStart = now.addingTimeInterval(-60 * 86400)
        var mostRecentDue: Date?
        for entry in entries where entry.cadence != .asNeeded {
            let due = MedicationRecurrenceEngine.occurrences(
                in: lookbackStart ... now,
                entry: entry,
                context: context
            )
            .map(\.at)
            .filter { $0 <= now }
            .max()
            if let due, due > (mostRecentDue ?? .distantPast) { mostRecentDue = due }
        }
        if let mostRecentDue { return mostRecentDue }

        var soonestUpcoming: Date?
        for entry in entries where entry.cadence != .asNeeded {
            if let next = MedicationRecurrenceEngine.nextOccurrence(
                after: now,
                entry: entry,
                context: context
            )?.at, next < (soonestUpcoming ?? .distantFuture) {
                soonestUpcoming = next
            }
        }
        return soonestUpcoming ?? now
    }
}
