import Foundation

// Moved out of `MedicationsStore.swift` for its `file_length` ceiling (pure
// code movement; private became internal for the sibling file).

extension MedicationsStore {
    /// Server doesn't return `archivedAt` (clientside-only field per the
    /// Medication model). Merge incoming rows with the in-memory map so
    /// that a fresh `load()` doesn't drop the local timestamp the user
    /// just saw when they archived. Pre-existing timestamps win only
    /// when the incoming row is still `active = false` — if the server
    /// has reactivated the medication, we drop the stale timestamp.
    func preservingLocalArchivedAt(in incoming: [Medication]) -> [Medication] {
        let localTimestamps: [String: Date] = Dictionary(uniqueKeysWithValues: medications
            .compactMap { medication -> (String, Date)? in
                guard let archivedAt = medication.archivedAt else { return nil }
                return (medication.id, archivedAt)
            })
        guard !localTimestamps.isEmpty else { return incoming }
        return incoming.map { row in
            guard !row.active, row.archivedAt == nil, let preserved = localTimestamps[row.id] else {
                return row
            }
            return Medication(
                id: row.id,
                name: row.name,
                dose: row.dose,
                treatmentClass: row.treatmentClass,
                category: row.category,
                dosesPerUnit: row.dosesPerUnit,
                schedule: row.schedule,
                lastTakenAt: row.lastTakenAt,
                todayEventCount: row.todayEventCount,
                notificationsEnabled: row.notificationsEnabled,
                active: row.active,
                archivedAt: preserved,
                trackIntake: row.trackIntake,
                recordedSchedule: row.recordedSchedule
            ).carryingCategoryLabel(row.categoryLabel)
        }
    }
}
