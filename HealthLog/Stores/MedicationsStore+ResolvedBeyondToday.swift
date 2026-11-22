import Foundation

/// **D3 #4 — a dose resolved for another day's slot silences that slot too.**
///
/// The reminder completion and the critical-alarm reconcile read only the
/// server's today list, and the server files a row there by its
/// `scheduledFor`. A weekly dose taken on Saturday that the server binds to
/// Sunday's slot is not in Saturday's list, the device that recorded it gets
/// no confirmation push (the sender is left out), and on Sunday at 09:00 the
/// reminder and the critical alarm came for a dose already taken.
///
/// For every medication whose cadence is not daily, the store reads the
/// server's `dose-history` around today and keeps the slots it reports as
/// taken or skipped. After the app's own take or skip of such a medication the
/// window is read at once; the slot a single-route write answers with is noted
/// before that. Every change runs `onIntakesDidChange`, which completes the
/// reminders, withdraws delivered banners and reconciles the alarms.
/// What the store knows about other days' resolved slots.
struct ResolvedBeyondToday {
    var slots: [MedicationReminderCompletion.ResolvedSlot] = []
    /// When each medication's window was last read, for the throttle.
    var readAt: [String: Date] = [:]
}

extension MedicationsStore {
    /// How far back the window reaches: yesterday's slots still have
    /// delivered banners to withdraw.
    nonisolated static let resolvedWindowLookBack: TimeInterval = 2 * 24 * 60 * 60
    /// How far ahead: a whole week, so a take bound to a slot up to a week
    /// out (every-N-weeks bands) is seen.
    nonisolated static let resolvedWindowLookAhead: TimeInterval = 8 * 24 * 60 * 60
    /// Loads within this span reuse the last read of a medication.
    nonisolated static let resolvedWindowThrottle: TimeInterval = 5 * 60

    /// Today's resolved slots and those of other days, once each.
    var allResolvedSlots: [MedicationReminderCompletion.ResolvedSlot] {
        Self.merging(MedicationReminderCompletion.resolvedSlots(in: derivedTodayIntakes), beyondToday.slots)
    }

    /// The taken or skipped slot rows of a `dose-history` ledger.
    nonisolated static func resolvedSlots(
        inLedger rows: [MedicationDoseHistoryRow],
        medicationId: String
    ) -> [MedicationReminderCompletion.ResolvedSlot] {
        rows.compactMap { row in
            guard row.kind == "slot" else { return nil }
            let resolved: Bool = if let state = row.stateRaw?.lowercased() {
                state == "taken" || state == "skipped"
            } else {
                switch row.status {
                case .takenOnTime, .takenLate, .skipped: true
                case .missed, .upcoming, .adHoc, nil: false
                }
            }
            return resolved ? .init(medicationId: medicationId, scheduledAt: row.at) : nil
        }
    }

    /// Whether a medication needs the window: it is reminded of, and some
    /// entry is not daily (a daily dose lands in today's list).
    nonisolated static func needsResolvedWindow(_ medication: Medication) -> Bool {
        guard MedicationReminderDeliveryPolicy.plansLocalReminder(for: medication) else { return false }
        return medication.schedule.entries.contains { entry in
            switch entry.cadence {
            case .daily, .asNeeded: false
            case let .legacy(days, intervalWeeks): intervalWeeks > 1 || !(days?.isEmpty ?? true)
            default: true
            }
        }
    }

    nonisolated static func merging(
        _ lhs: [MedicationReminderCompletion.ResolvedSlot],
        _ rhs: [MedicationReminderCompletion.ResolvedSlot]
    ) -> [MedicationReminderCompletion.ResolvedSlot] {
        var result = lhs
        for slot in rhs where !result.contains(slot) {
            result.append(slot)
        }
        return result
    }
}
