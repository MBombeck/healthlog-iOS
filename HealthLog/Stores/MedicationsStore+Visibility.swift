import Foundation

/// The two display lists of the Medications tab. Both are cut from
/// `activeMedications` and keep its saved order; `activeMedications` itself
/// stays the full list, because reminders, the badge, the watch and the
/// widgets read it and hiding must not reach them.
public extension MedicationsStore {
    func visibleActiveMedications(hiding hiddenIDs: Set<String>) -> [Medication] {
        guard !hiddenIDs.isEmpty else { return activeMedications }
        return activeMedications.filter { !hiddenIDs.contains($0.id) }
    }

    func hiddenActiveMedications(hiding hiddenIDs: Set<String>) -> [Medication] {
        guard !hiddenIDs.isEmpty else { return [] }
        return activeMedications.filter { hiddenIDs.contains($0.id) }
    }

    /// Archive and take the medication out of the hidden selection, so it only
    /// ever stands under „Archiviert“.
    @discardableResult
    func archive(id: String, releasingFrom visibility: MedicationVisibilityStore?) async -> WriteOutcome {
        visibility?.unhide(id)
        return await archive(id: id)
    }

    /// Restore from the archive; a restored medication comes back visible.
    @discardableResult
    func unarchive(id: String, releasingFrom visibility: MedicationVisibilityStore?) async -> WriteOutcome {
        visibility?.unhide(id)
        return await unarchive(id: id)
    }
}

/// The order the „Anpassen“ sheet sends to the server.
///
/// The sheet only shows visible medications, but the saved order covers all of
/// them. A hidden id keeps its slot; the visible slots are filled with the new
/// visible order. No id of the full order is ever dropped.
enum MedicationVisibilityOrder {
    static func merged(fullOrder: [String], visibleOrder: [String], hidden: Set<String>) -> [String] {
        let visibleInFull = fullOrder.filter { !hidden.contains($0) }
        var seen = Set<String>()
        // The new visible order first, then any visible id the sheet did not
        // hand back, so a short list cannot lose one.
        var queue = (visibleOrder + visibleInFull).filter { !hidden.contains($0) && seen.insert($0).inserted }
        var result: [String] = []
        result.reserveCapacity(fullOrder.count)
        for id in fullOrder {
            if hidden.contains(id) {
                result.append(id)
            } else if !queue.isEmpty {
                result.append(queue.removeFirst())
            }
        }
        return result + queue
    }
}
