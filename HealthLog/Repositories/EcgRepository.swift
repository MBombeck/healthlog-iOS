import Foundation

/// Ephemeral owner + credential generation captured by one HealthKit ECG
/// sweep. The bearer is never persisted or logged. Pinning it into the request
/// prevents an A payload from inheriting B's ambient Keychain token after an
/// async HealthKit read; the validator stops progress after logout, rotation,
/// or an account switch.
struct EcgUploadAuthenticationLease: Sendable {
    enum ValidationError: Error, Sendable {
        case staleAuthentication
    }

    let ownerUserID: String
    private let bearerToken: String
    private let isCurrentProvider: @Sendable () -> Bool

    init(
        ownerUserID: String,
        bearerToken: String,
        isCurrent: @escaping @Sendable () -> Bool
    ) {
        self.ownerUserID = ownerUserID
        self.bearerToken = bearerToken
        isCurrentProvider = isCurrent
    }

    var authorizationHeader: String {
        "Bearer \(bearerToken)"
    }

    var isCurrent: Bool {
        !Task.isCancelled && isCurrentProvider()
    }

    func validate() throws {
        guard isCurrent else { throw ValidationError.staleAuthentication }
    }
}

/// Wraps the ECG reads and v1.37.3 ingest contract:
///   - `GET /api/insights/ecg` → ``EcgListDTO`` — metadata only, never a
///     waveform (the route omits `waveformEncrypted` from its `select`).
///   - `GET /api/insights/ecg/[id]` → ``EcgDetailDTO`` — one recording's
///     decrypted, min/max-decimated trace.
///
/// A thin read-only `actor` over the shared `APIClient`, mirroring
/// ``RhythmEventsRepository`` — the two surfaces sit behind the SAME server
/// gates (`insights` module AND the `insightStatus` assistant surface), so they
/// fail closed the same way.
///
/// **Cache strategy.** The LIST routes through the Berlin-day-anchored
/// `.insightsEcg` SWR ladder: recordings arrive a handful of times a year, so
/// the surface paints cache-first on launch and revalidates once per day. The
/// DETAIL is never cached at any layer — the server answers `no-store` and the
/// samples are decrypted health data.
///
/// **`nil` arms (fail-closed + calm).** `403` (module off OR assistant surface
/// off), `404` (route absent / unknown-or-foreign id) and `422` all resolve to
/// `nil`. The pill never appears, the page never mounts, and no error is ever
/// shown for a surface the account simply does not have.
public actor EcgRepository {
    private let api: APIClientProtocol
    /// Optional persistent daily SWR cache for the LIST. When wired, the list
    /// paints from the on-disk `.insightsEcg(day:)` snapshot first and
    /// revalidates in the background. `nil` keeps the direct-fetch unit-test
    /// ergonomics.
    private let swr: SWRCoordinator?

    public init(api: APIClientProtocol, swr: SWRCoordinator? = nil) {
        self.api = api
        self.swr = swr
    }

    /// Fetches the recording METADATA list.
    ///
    /// - Returns: the list (including the empty `hasRecordings: false` shape,
    ///   which decodes normally and gates the surface off), or `nil` when the
    ///   read is gated / absent.
    public func fetchList() async throws -> EcgListDTO? {
        let api = api
        @Sendable func networkFetch() async throws -> EcgListDTO {
            let request: APIRequest<EcgListDTO> = .get(HealthIngestRoute.ecgList)
            return try await api.send(request)
        }
        do {
            if let swr {
                return try await swr.fetchCachingFirst(
                    .insightsEcg(day: BerlinDayKey.string()),
                    decoding: EcgListDTO.self,
                    fetch: networkFetch
                )
            }
            return try await networkFetch()
        } catch let HLError.server(status, _, _) where status == 403 || status == 404 || status == 422 {
            // Module off / assistant surface off / route absent → the whole ECG
            // surface hides. Never an error.
            return nil
        }
    }

    /// Fetches ONE recording with its waveform.
    ///
    /// Deliberately un-cached: the server sends `no-store` and the payload is a
    /// decrypted health-data trace, so it never touches the SWR ladder or disk.
    ///
    /// - Returns: the recording, or `nil` for an unknown / foreign id (`404` —
    ///   ownership is narrowed server-side in the `where`) or a gated read.
    public func fetchDetail(id: String) async throws -> EcgDetailDTO? {
        let request: APIRequest<EcgDetailDTO> = .get(HealthIngestRoute.ecgDetail(id: id))
        do {
            return try await api.send(request)
        } catch let HLError.server(status, _, _) where status == 403 || status == 404 || status == 422 {
            return nil
        }
    }

    /// Uploads ONE recording to `POST /api/insights/ecg` (server v1.37.3,
    /// GH #74). The route takes no batch — one recording per request.
    ///
    /// **Errors are thrown, not swallowed.** This is the deliberate opposite of
    /// the reads above, where `403`/`404`/`422` all resolve to `nil` so a
    /// surface the account does not have never shows an error. A write has to
    /// tell its caller *which* way it failed: ``EcgSyncCoordinator`` decides
    /// between "skip this recording forever" and "hold the cursor and come
    /// back", and it cannot make that call on a `nil`.
    ///
    /// **No `Idempotency-Key`.** The server states plainly that it does not
    /// evaluate one on this route: the recording carries its own identity
    /// (`HKSample.uuid` plus the unique index on
    /// `(userId, source, recordedAt, samplingFrequency)`), so a retry lands on
    /// the same row structurally rather than by way of a cached response. An
    /// `IdempotencyKey()` here would be header traffic that changes nothing.
    ///
    /// The list cache is invalidated on a write that actually changed something
    /// (`inserted`/`updated`), so the ECG surface repaints from the server
    /// rather than from yesterday's day-anchored snapshot. A `duplicate` wrote
    /// nothing and leaves the cache alone.
    public func uploadRecording(_ payload: EcgIngestRequestDTO) async throws -> EcgIngestResponseDTO {
        try await uploadRecording(payload, requiring: nil)
    }

    /// Account-leased upload used by the long-running HealthKit sweep. The
    /// explicit bearer belongs to the initiating owner generation, so the
    /// shared API client's ambient Keychain credential can never replace it.
    func uploadRecording(
        _ payload: EcgIngestRequestDTO,
        requiring authLease: EcgUploadAuthenticationLease
    ) async throws -> EcgIngestResponseDTO {
        try await uploadRecording(payload, requiring: Optional(authLease))
    }

    private func uploadRecording(
        _ payload: EcgIngestRequestDTO,
        requiring authLease: EcgUploadAuthenticationLease?
    ) async throws -> EcgIngestResponseDTO {
        guard payload.samples.count <= EcgIngestRequestDTO.maxSamples else {
            throw HLError.server(
                status: 413,
                code: "ecg.client.samples.too_large",
                message: "ECG request exceeds the released sample limit"
            )
        }
        let base: APIRequest<EcgIngestResponseDTO> = try .post(
            HealthIngestRoute.ecgIngest,
            body: payload,
            encoder: .hlDefault,
            idempotencyKey: .notSent
        )
        guard let body = base.body, body.count <= EcgIngestRequestDTO.maxBodyBytes else {
            throw HLError.server(
                status: 413,
                code: "ecg.client.body.too_large",
                message: "ECG request exceeds the released body limit"
            )
        }
        try authLease?.validate()
        let request = APIRequest<EcgIngestResponseDTO>(
            method: base.method,
            path: base.path,
            query: base.query,
            body: base.body,
            extraHeaders: authLease.map { ["Authorization": $0.authorizationHeader] } ?? base.extraHeaders,
            idempotencyKey: base.idempotencyKey,
            // A leased health payload must cross at most one wire boundary.
            // A later sweep can retry after recapturing the live account.
            maxRetries: authLease == nil ? base.maxRetries : 0,
            failFast: base.failFast,
            streaming: base.streaming,
            // A 401 for A's pinned bearer must not refresh/logout whichever
            // account currently owns the process-global auth session.
            allowsAuthenticationRecovery: authLease == nil
        )
        let response: EcgIngestResponseDTO
        do {
            response = try await api.send(request)
        } catch {
            // Prefer the stale-generation verdict if auth changed during the
            // transport; otherwise retain the original transport/server error.
            try authLease?.validate()
            throw error
        }
        try authLease?.validate()
        if response.status != .duplicate {
            await invalidateCache()
        }
        return response
    }

    /// Drops the cached list (logout wipe).
    public func invalidateCache() async {
        await swr?.invalidate([.insightsEcg(day: BerlinDayKey.string())])
    }
}
