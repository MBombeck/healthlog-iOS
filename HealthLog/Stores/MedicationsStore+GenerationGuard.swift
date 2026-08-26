import Foundation

// audit-v0162 H-3 — mutation-generation guard helpers, split out of
// `MedicationsStore.swift` so the store stays under SwiftLint's `file_length`
// ceiling (pure code movement; the stored `mutationGeneration` property lives in
// the class body because Swift stored properties can't be declared in extensions).

extension MedicationsStore {
    /// audit-v0162 H-3 — bump the mutation generation. Reached from the
    /// `+IntakeMutations` / `+CRUD` extension files.
    func bumpMutationGeneration() {
        mutationGeneration &+= 1
    }

    /// audit-v0162 H-3 — current generation (observe-start capture + tests).
    var currentMutationGeneration: UInt64 {
        mutationGeneration
    }

    /// audit-v0162 H-3 — apply a today-intakes SWR payload under the generation
    /// guard. Returns `true` when applied; `false` (dropped) when a concurrent
    /// optimistic mark advanced the generation past `loadGeneration` — the stale
    /// fetch must not repaint a marked dose back to pending (badge climb-back).
    @discardableResult
    func applyTodayIntakes(_ value: [MedicationIntake], loadGeneration: UInt64) -> Bool {
        guard mutationGeneration == loadGeneration else { return false }
        todayIntakes = value
        onIntakesDidChange?()
        return true
    }
}
