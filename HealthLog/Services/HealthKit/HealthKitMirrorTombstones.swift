import Foundation

/// **S1 / public #11, A6 (1.4)** — server ids whose HealthLog copy the person
/// deleted in Apple Health, so the server→Health mirror does not write them
/// back.
///
/// Deleting a copy in Apple Health keeps the server row: the delete route only
/// touches `APPLE_HEALTH` rows, and a copy is never uploaded. Without this list
/// the next fresh page would mirror the reading straight back. The deletion
/// path records the id it reads from the copy's sync identifier
/// (``HealthKitCopySyncIdentity``); the mirror reads the list. Until 1.4 the
/// only writer looked for metadata a deletion never keeps, so the list stayed
/// empty and the global 1.3 key (`…tombstones.v1`) was never written.
///
/// Per owner, keyed by the same partition token as the other per-account
/// HealthKit state, so one account's list never limits another's mirror. Not
/// cleared at sign-out: after the next sign-in the anchors start over and do
/// not report an old deletion again, so an emptied list would let the mirror
/// write back every copy the person ever deleted. The ids are server row ids
/// and carry no health data. Each list keeps the newest ``capacity`` ids.
struct HealthKitMirrorTombstones: @unchecked Sendable {
    static let keyPrefix = "hl.healthkit.serverMirror.tombstones.v2."
    static let capacity = 2000

    let key: String
    /// `UserDefaults` is thread-safe; the box is only `@unchecked` because
    /// the type itself is not declared `Sendable`.
    private let defaults: UserDefaults

    init(ownerID: String?, defaults: UserDefaults = .standard) {
        key = Self.keyPrefix + HealthKitBackfillWindowStore.partitionToken(for: ownerID)
        self.defaults = defaults
    }

    var ids: Set<String> {
        Set(defaults.stringArray(forKey: key) ?? [])
    }

    func record(_ newIDs: [String]) {
        var seen = Set<String>()
        let additions = newIDs.filter { !$0.isEmpty && seen.insert($0).inserted }
        guard !additions.isEmpty else { return }
        var stored = defaults.stringArray(forKey: key) ?? []
        stored.removeAll { seen.contains($0) }
        stored.append(contentsOf: additions)
        if stored.count > Self.capacity {
            stored.removeFirst(stored.count - Self.capacity)
        }
        defaults.set(stored, forKey: key)
    }
}
