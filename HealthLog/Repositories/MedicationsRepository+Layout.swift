import Foundation

/// **M2 (AUDIT-PARITY-v11612)** — per-account medications-list presentation
/// (`GET/PUT /api/medications/layout`). Lives in its own extension so the
/// actor body stays under the type-body-length budget.
public extension MedicationsRepository {
    /// Fetch the resolved list layout (view + manual order, server defaults
    /// merged in). Throws in standalone mode (no server) — callers treat any
    /// failure as "no saved layout" and keep the default server order.
    func listLayout() async throws -> MedicationListLayout {
        if isStandaloneActive { throw HLError.offline }
        let req: APIRequest<MedicationListLayout> = .get("/api/medications/layout")
        let layout = try await api.send(req)
        // CU-20 — refresh the token the next PUT will echo as `baseUpdatedAt`.
        listLayoutToken = layout.updatedAt
        return layout
    }

    /// Test/diagnostic accessor for the currently held concurrency token.
    func currentListLayoutToken() -> String? {
        listLayoutToken
    }

    /// Persist a layout change (preserve-when-absent — only the supplied
    /// field is written, the other is kept server-side). Returns the resolved
    /// layout the server echoes.
    ///
    /// **CU-20 (#69):** guarded by `baseUpdatedAt`. A stale token yields
    /// `409 medication_layout_conflict` with nothing written; the bounded retry
    /// re-GETs and re-sends. Bounded rather than looping because this GET sits
    /// behind a 300 s server-side cache invalidated only by this route's own
    /// writes, so a re-read after a conflict caused by an unrelated account
    /// write can hand back the same stale token.
    @discardableResult
    func updateListLayout(_ patch: MedicationListLayoutPatch) async throws -> MedicationListLayout {
        if isStandaloneActive { throw HLError.offline }
        return try await withOptimisticConflictRetry(
            conflictCode: OptimisticConflictCode.medicationLayout,
            token: listLayoutToken
        ) { token in
            let req: APIRequest<MedicationListLayout> = try .put(
                "/api/medications/layout",
                body: OptimisticWriteBody(payload: patch, baseUpdatedAt: token)
            )
            let echoed = try await api.send(req)
            listLayoutToken = echoed.updatedAt
            return echoed
        } reread: {
            // Preserve-when-absent patch — the pending change is still correct
            // against the refreshed state; only the token moves.
            try await listLayout().updatedAt
        }
    }
}
