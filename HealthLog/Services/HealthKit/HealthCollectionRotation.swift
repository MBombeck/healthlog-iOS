import Foundation

/// **V1 (1.2, HealthLog#1173)** — where the next sample collection starts.
///
/// The collection walks its thirty-five types in one fixed (alphabetical)
/// order, and a short wake (AppRefresh, silent push) that runs out of time
/// stops wherever it is. Every such wake then served the same front of the
/// list again, and the back of it (stair speeds, walking speed, step length,
/// asymmetry, double support, walking heart rate) waited for the next
/// "Sync all". The field report shows exactly that split.
///
/// The fix is a persisted offset: a pass that ends early moves the start to
/// the first type it did not finish, so the next wake begins there. A pass
/// that finishes every type leaves the offset alone. Nothing is skipped and
/// nothing is read twice in one pass; only the starting point moves.
enum HealthCollectionRotation {
    static let offsetKey = "hl.healthkit.collectionRotationOffset"

    /// `types` rotated to start at the persisted offset.
    static func ordered(_ types: [String], defaults: UserDefaults) -> [String] {
        guard !types.isEmpty else { return types }
        let offset = max(0, defaults.integer(forKey: offsetKey)) % types.count
        return Array(types[offset...] + types[..<offset])
    }

    /// Records how far a pass over `ordered` got. `finished` is the number of
    /// leading types that ran to an end; fewer than all moves the start there.
    static func advance(finished: Int, of count: Int, defaults: UserDefaults) {
        guard count > 0, finished < count else { return }
        let offset = max(0, defaults.integer(forKey: offsetKey)) % count
        defaults.set((offset + max(0, finished)) % count, forKey: offsetKey)
    }
}
