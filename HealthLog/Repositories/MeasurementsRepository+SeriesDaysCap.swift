import Foundation

// MARK: - W1 Fix 1 — `/api/measurements/series` days-cap clamp

public extension MeasurementsRepository {
    /// Upper bound the server's `/api/measurements/series` route accepts on its
    /// `days` query param. Anything above this returns a Zod `too_big` →
    /// HTTP 422.
    ///
    /// **W-SERVER-SYNC (server v1.5.5):** the server raised its cap from 365 to
    /// 3650, so the iOS `.all` range (`ChartDetailStore.Range.all = 3650`) can
    /// finally request the real all-time span again. The interim 365 clamp —
    /// which surfaced "All data" as only the trailing year — is removed: the
    /// cap now equals `.all` so `clampDays` is a no-op for every shipped range
    /// and `.all` carries the full span to the wire. The clamp stays in place
    /// as a defensive floor/ceiling (`1…3650`) so a future range can never
    /// 422 the server.
    static let serverDaysCap = 3650

    /// Clamps a requested `days` window into the range the server accepts
    /// (`1…serverDaysCap`). Pure + `nonisolated` so unit tests can pin the
    /// boundary without spinning up the actor. See `serverDaysCap` for the
    /// server-team dependency that would let us request true all-time.
    nonisolated static func clampDays(_ days: Int) -> Int {
        min(max(days, 1), serverDaysCap)
    }
}
