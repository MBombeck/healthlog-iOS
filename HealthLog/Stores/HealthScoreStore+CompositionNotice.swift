import Foundation

// #115 B6 — the composition note ("Sleep left the score") could be read but
// never put away: the app decoded `compositionNotice.dismissed` and had no way
// to set it. The server takes the dismissal on the same route the web uses,
// `POST /api/daily/digest/dismiss` with the notice's `itemKey`
// (`health-score:` prefix, `DISMISSIBLE_NOTICE_PREFIXES` at v1.39.0), and
// evicts its cached score report so the next read says `dismissed: true`.

public extension AnalyticsRepository {
    /// Persists the dismissal of a Health Score notice server-side (an
    /// owner-scoped upsert, so a repeat is a no-op).
    func dismissScoreNotice(itemKey: String) async throws {
        let req: APIRequest<EmptyResponse> = try .post(
            "/api/daily/digest/dismiss",
            body: ScoreNoticeDismissBody(itemKey: itemKey)
        )
        _ = try await api.send(req)
    }
}

private struct ScoreNoticeDismissBody: Encodable {
    let itemKey: String
}

public extension HealthScore {
    /// The same score with its composition note marked dismissed — what the
    /// server's next read will say, applied now so the note goes at once.
    func withCompositionNoticeDismissed() -> HealthScore {
        guard let notice = compositionNotice else { return self }
        return HealthScore(
            score: score, band: band, delta: delta, confidence: confidence,
            composition: composition, configured: configured, deltaReason: deltaReason,
            scoreVersion: scoreVersion, bandSetter: bandSetter, restMode: restMode,
            scoreBasis: scoreBasis,
            compositionNotice: HealthScoreCompositionNotice(
                itemKey: notice.itemKey, left: notice.left, joined: notice.joined, dismissed: true
            )
        )
    }
}

public extension HealthScoreStore {
    /// Put the composition note away. The note disappears only once the
    /// server has stored the dismissal; a failed request leaves it on screen
    /// (nothing claims a dismissal the server does not know) and returns
    /// `false` so the surface can say so.
    @discardableResult
    func dismissCompositionNotice() async -> Bool {
        guard let current = score, let notice = current.compositionNotice, notice.isShowable else { return false }
        do {
            try await analyticsRepository.dismissScoreNotice(itemKey: notice.itemKey)
        } catch {
            return false
        }
        // The note may have changed while the request was out; only mark the
        // one that was dismissed.
        if score?.compositionNotice?.itemKey == notice.itemKey {
            applyDismissedCompositionNotice()
        }
        await swrCoordinator?.invalidate([.healthScore])
        return true
    }
}
