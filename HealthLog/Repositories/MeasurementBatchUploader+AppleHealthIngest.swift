import Foundation

// The live wire calls of the Apple Health ingest v2: one symptom page and one
// batch of deletions, under the same pinned bearer and throttle as the
// measurement batch.

extension MeasurementBatchUploader {
    /// Posts one symptom page (at most 500 rows) and returns the server's
    /// per-entry answer. Throws on transport and whole-call refusals.
    func uploadSymptoms(_ entries: [AppleHealthSymptomEntryDTO]) async throws -> HealthKitBatchResponseDTO {
        let lease = try captureAuthenticationLeaseIfConfigured()
        try await throttle.acquire()
        try lease?.validate()
        let base: APIRequest<HealthKitBatchResponseDTO> = try .post(
            AppleHealthIngestRoute.symptomsBatch,
            body: AppleHealthSymptomBatchPayload(entries: entries),
            encoder: .hlBatch,
            idempotencyKey: IdempotencyKey()
        )
        let response = try await api.send(Self.pinned(base, lease))
        try lease?.validate()
        return response
    }

    /// Sends one batch of deleted sample UUIDs to `domain`'s route.
    func deleteAppleHealthRecords(_ externalIDs: [String], domain: AppleHealthDeleteDomain) async throws {
        guard !externalIDs.isEmpty else { return }
        let lease = try captureAuthenticationLeaseIfConfigured()
        try await throttle.acquire()
        try lease?.validate()
        let base: APIRequest<EmptyResponse> = try .delete(domain.path, body: ExternalIDBatch(externalIds: externalIDs))
        _ = try await api.send(Self.pinned(base, lease))
        try lease?.validate()
    }

    private static func pinned<R: Sendable>(_ base: APIRequest<R>, _ lease: MeasurementUploadAuthenticationLease?) -> APIRequest<R> {
        APIRequest<R>(
            method: base.method,
            path: base.path,
            query: base.query,
            body: base.body,
            extraHeaders: lease.map { ["Authorization": $0.authorizationHeader] } ?? base.extraHeaders,
            idempotencyKey: base.idempotencyKey,
            maxRetries: lease == nil ? base.maxRetries : 0,
            failFast: base.failFast,
            streaming: base.streaming,
            allowsAuthenticationRecovery: lease == nil
        )
    }
}
