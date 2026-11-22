import Foundation

// MARK: - A commit replaces only the cursor it read

extension DurableHealthCursorStore {
    /// ``commit(page:anchor:for:requiring:)``, refused when the stored cursor
    /// is no longer the one this run read (`expected`).
    ///
    /// Two runs of one partition are serialised (``HealthPartitionTurns``), so
    /// this should never trip. It is the guard behind that rule: a run that
    /// finishes late must not write its older anchor over one another run
    /// already moved further. The page it sent is folded on the server by its
    /// `externalId`; the later cursor stands.
    @discardableResult
    func commit(
        page outcome: HealthSyncPageOutcome,
        anchor: Data,
        for key: HealthSyncCursorKey,
        requiring lease: HealthSyncAuthenticatedLease,
        replacing expected: Data?
    ) -> HealthSyncCommitDecision {
        guard self.anchor(for: key) == expected else {
            return .hold(reason: .superseded)
        }
        return commit(page: outcome, anchor: anchor, for: key, requiring: lease)
    }
}
