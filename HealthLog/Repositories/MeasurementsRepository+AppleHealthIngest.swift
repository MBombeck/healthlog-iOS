import Foundation

// The replay's wire calls for the Apple Health ingest v2 outbox kinds. Same
// shape as the workout replay: a captured bearer is pinned so a 401 refresh
// cannot rebuild account A's request under account B.

extension MeasurementsRepository {
    func replayAppleHealthSymptoms(
        _ entries: [AppleHealthSymptomEntryDTO],
        idempotencyKey: String,
        authLease: OutboxQueue.AuthLease?
    ) async throws -> HealthKitBatchResponseDTO {
        let base: APIRequest<HealthKitBatchResponseDTO> = try .post(
            AppleHealthIngestRoute.symptomsBatch,
            body: AppleHealthSymptomBatchPayload(entries: entries),
            encoder: .hlBatch,
            idempotencyKey: IdempotencyKey(raw: idempotencyKey)
        )
        return try await sendPinned(base, authLease: authLease)
    }

    func replayAppleHealthDeletion(
        _ externalIDs: [String],
        domain: AppleHealthDeleteDomain,
        authLease: OutboxQueue.AuthLease?
    ) async throws {
        guard !externalIDs.isEmpty else { return }
        let base: APIRequest<EmptyResponse> = try .delete(domain.path, body: ExternalIDBatch(externalIds: externalIDs))
        _ = try await sendPinned(base, authLease: authLease)
    }

    private func sendPinned<R: Decodable & Sendable>(
        _ base: APIRequest<R>,
        authLease: OutboxQueue.AuthLease?
    ) async throws -> R {
        if let authLease { try await outbox.validateAuthLease(authLease) }
        let headers: [String: String] = if let header = authLease?.authorizationHeader {
            ["Authorization": header]
        } else {
            base.extraHeaders
        }
        let req = APIRequest<R>(
            method: base.method,
            path: base.path,
            query: base.query,
            body: base.body,
            extraHeaders: headers,
            idempotencyKey: base.idempotencyKey,
            maxRetries: base.maxRetries,
            failFast: base.failFast,
            streaming: base.streaming,
            allowsAuthenticationRecovery: authLease == nil
        )
        do {
            let response = try await api.send(req)
            if let authLease { try await outbox.validateAuthLease(authLease) }
            return response
        } catch {
            if let authLease { try await outbox.validateAuthLease(authLease) }
            throw error
        }
    }
}
