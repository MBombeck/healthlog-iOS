import Foundation

/// Wraps the correlation-pattern *decision ledger* (server v1.34.0):
/// `GET /api/insights/patterns` and `PATCH /api/insights/patterns/{id}`.
///
/// **What "dismiss" means here.** It records that the person said *"this is not
/// relevant for me"* — it is NOT a claim that the pair is wrong, and NOT a
/// delete. The server keeps the row, freezes the evidence baseline, and the
/// same route takes it back with `{ "dismissed": false }`. This repository
/// therefore exposes ONE symmetric write, not a `dismiss()` verb.
///
/// **Server-authoritative, deliberately uncached.** `GET /api/insights/patterns`
/// is `force-dynamic` server-side and dismissal state can change *outside* any
/// client action: the recomputation that runs inside
/// `GET /api/insights/correlations` clears a dismissal on its own when the
/// evidence moved materially. Caching the ledger would let the app paint a
/// dismissal the server has already lifted, so this repository has no SWR row —
/// it re-reads.
///
/// **Graceful gating.** A `403 module.disabled` (module `insights`) or a `404`
/// from a server that predates the route maps to `nil` on the read, so the
/// surface hides quietly instead of erroring. Every other failure — including
/// the `404` a *withdrawn* pattern answers a PATCH with — is thrown, because a
/// write that did not happen must never look like one that did.
public actor PatternsRepository {
    private let api: APIClientProtocol

    public init(api: APIClientProtocol) {
        self.api = api
    }

    /// Body of `PATCH /api/insights/patterns/{id}`. The server validates it
    /// with a `strictObject`, so `dismissed` is the only permitted key AND is
    /// mandatory — any extra key is a `422`.
    private struct DismissedBody: Encodable {
        let dismissed: Bool
    }

    /// The full current ledger, or `nil` when the `insights` module is off / the
    /// route is not deployed.
    ///
    /// Returns dismissed rows too (the route applies no `dismissedAt` filter) —
    /// callers distinguish on ``CorrelationPattern/isDismissed``. Rows the
    /// server has withdrawn (`isCurrent = false`) are not included and cannot
    /// be patched.
    public func fetch() async throws -> [CorrelationPattern]? {
        do {
            let req: APIRequest<CorrelationPatternsResponse> = .get("/api/insights/patterns")
            return try await api.send(req).patterns
        } catch HLError.moduleDisabled {
            // #30 — `APIClient` types the `insights` module-gate 403; the
            // surface is off, which is a hidden block, not a failure.
            return nil
        } catch let HLError.server(status, code, _)
            where status == 404 || (status == 403 && code == "module.disabled")
        {
            return nil
        }
    }

    /// Records the person's relevance statement for one pattern and returns the
    /// server's five-field delta.
    ///
    /// - Parameters:
    ///   - dismissed: `true` = "not relevant for me", `false` = take that back.
    ///   - patternId: the pattern row's **cuid**. `canonicalKey` is NOT a valid
    ///     path parameter for this route.
    /// - Returns: the settled state. Reconcile the UI against
    ///   ``CorrelationPatternDismissal/dismissed`` rather than against the value
    ///   that was sent.
    /// - Throws: `HLError.server(404, …)` when the pattern is unknown, belongs
    ///   to someone else, or has been withdrawn (`isCurrent = false`) — a
    ///   withdrawn pattern can be neither dismissed nor restored.
    public func setDismissed(_ dismissed: Bool, patternId: String) async throws -> CorrelationPatternDismissal {
        let req: APIRequest<CorrelationPatternDismissal> = try .patch(
            "/api/insights/patterns/\(patternId)",
            body: DismissedBody(dismissed: dismissed)
        )
        return try await api.send(req)
    }
}
