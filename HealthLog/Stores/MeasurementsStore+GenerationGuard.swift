import Foundation

// Mutation-generation guard helpers, split out of
// `MeasurementsStore.swift` so the store stays under SwiftLint's `file_length`
// ceiling (pure code movement; the stored `mutationGeneration` property lives in
// the class body because Swift stored properties can't be declared in extensions).

extension MeasurementsStore {
    /// Bump the mutation generation. Called at the head of
    /// every optimistic `recent` mutation (incl. the focused `+QuickCapture` /
    /// `+BulkDelete` extensions).
    func bumpMutationGeneration() {
        mutationGeneration &+= 1
    }

    /// Read the current generation (observe-start capture +
    /// tests).
    var currentMutationGeneration: UInt64 {
        mutationGeneration
    }

    /// Apply a `.cached` recent payload under the generation
    /// guard. Returns `true` when applied; `false` (dropped) when a concurrent
    /// optimistic mutation advanced the generation past `loadGeneration`.
    @discardableResult
    func applyCachedRecent(_ value: [Measurement], loadGeneration: UInt64) -> Bool {
        guard mutationGeneration == loadGeneration else { return false }
        recent = value
        isShowingStaleCache = true
        lastUpdatedAt = Date()
        return true
    }

    /// Apply a `.fresh` recent payload under the generation
    /// guard. Returns `true` when applied; `false` (dropped) when a concurrent
    /// optimistic mutation advanced the generation — the stale fetch must not
    /// resurrect a deleted row or clobber an in-flight edit.
    @discardableResult
    func applyFreshRecent(_ value: [Measurement], loadGeneration: UInt64) -> Bool {
        guard mutationGeneration == loadGeneration else { return false }
        recent = value
        isShowingStaleCache = false
        lastUpdatedAt = Date()
        return true
    }
}
