import Foundation

/// **The verdict half of ``CycleStore`` (Z1 / #72).**
///
/// Split out of `CycleStore.swift` under the repo's file-length discipline. Pure
/// movement plus the ``CycleStore/publishVerdict(_:restored:)`` seam, which
/// exists so this extension can write the store's state without relaxing
/// `private(set)` on the app's most sensitive store.
///
/// **The rule.** `state`, `phase` and `overdueDays` come from the server, or
/// from the last thing the server said, and from nowhere else. The on-device
/// engine still computes the FORECAST offline (dates, bands, expected next
/// start) with its provenance on the screen; it does not compute the JUDGEMENT.
/// The server resolves "today" from the PROFILE timezone, which an offline
/// device does not necessarily hold — on a trip "today" can be a day out. In a
/// forecast that is a rounding error. In "overdue" it is a false statement about
/// a person's body, and she cannot see why it is wrong.
extension CycleStore {
    /// Take the server's resolved verdict and store it for the offline path.
    ///
    /// A server older than v1.35.2 publishes no verdict. In that case the app
    /// makes NO state claim: it does not reconstruct one from `dayOfCycle` and
    /// `cycleLength`, and it does not fall back to a snapshot taken from a
    /// different server, because nothing bounds how far that has drifted.
    func applyServerVerdict(_ dto: CycleVerdictDTO?, generatedAt: Date?) async {
        guard let dto else {
            publishVerdict(nil, restored: false)
            return
        }
        // `meta.generatedAt` is when the SERVER resolved it. The receive time
        // would overstate freshness — the envelope may come from the cache.
        let snapshot = CycleVerdictSnapshot(verdict: dto, asOf: generatedAt ?? .now)
        publishVerdict(snapshot, restored: false)
        await repository.persistVerdict(snapshot)
    }

    /// Bring back the last server verdict for a load that could not reach the
    /// server, flagged so the surface dates it ("Stand: Gestern, 14:20").
    ///
    /// Dropped entirely once it has outlived its own horizon
    /// (``CycleVerdictSnapshot/horizon``): past that point saying nothing is
    /// more honest than a dated statement that can no longer answer the question
    /// the reader is asking it.
    func restoreStoredVerdict() async {
        var candidate = verdict
        if candidate == nil {
            candidate = await repository.storedVerdict()
        }
        guard let candidate, candidate.isShowable() else {
            publishVerdict(nil, restored: false)
            return
        }
        publishVerdict(candidate, restored: true)
    }
}
