import Foundation

// Replay arms for the Apple Health ingest v2 kinds: symptom pages and
// deletions by externalId. Both run under the row's own owner lease; an owner
// transition is retryable, never a reason to drop the row.

extension OutboxReplayService {
    func dispatchAppleHealthIngest(_ op: OutboxQueue.Operation) async throws {
        do {
            var authLease: OutboxQueue.AuthLease?
            if let owner = op.ownerUserID {
                authLease = try await outbox.captureAuthLease(requiringOwner: owner)
            }
            switch op.kind {
            case .uploadAppleHealthSymptoms:
                let p = try decoder.decode(OutboxQueue.Payloads.UploadAppleHealthSymptoms.self, from: op.payload)
                guard !p.entries.isEmpty else { return }
                let response = try await measurementsRepo.replayAppleHealthSymptoms(
                    p.entries,
                    idempotencyKey: op.idempotencyKey,
                    authLease: authLease
                )
                if let missing = AppleHealthSymptomAcceptance.unproven(postedCount: p.entries.count, response: response) {
                    // Counts only: the page stays for the next pass.
                    throw HLError.network(.other("symptom page not fully accepted (\(missing) open)"))
                }
                // A refused symptom is never dropped in silence.
                let refused = AppleHealthSymptomAcceptance.refusals(in: response, posted: p.entries)
                if !refused.isEmpty {
                    guard let owner = op.ownerUserID else { throw HealthKitReplayParked(reason: .refusalNotRecorded) }
                    do {
                        try await HealthKitSkippedRowRegister.current.record(
                            refused.map { HealthKitSkippedEntry(symptom: $0.entry, reason: $0.reason) },
                            ownerID: owner,
                            build: HealthKitSkipRegisterBuild.current
                        )
                    } catch {
                        throw HealthKitReplayParked(reason: .refusalNotRecorded)
                    }
                }
            case .deleteAppleHealthRecords:
                let p = try decoder.decode(OutboxQueue.Payloads.DeleteAppleHealthRecords.self, from: op.payload)
                try await measurementsRepo.replayAppleHealthDeletion(p.externalIds, domain: p.domain, authLease: authLease)
            default:
                break
            }
        } catch is OutboxQueue.OwnerLeaseError {
            throw HLError.authenticatedSessionChanged
        }
    }
}

/// Which indexes of a symptom page the server answered for good. Landed
/// (`inserted`, `updated`, `duplicate`) and terminal skips count; a `failed`
/// or missing index does not.
enum AppleHealthSymptomAcceptance {
    /// `nil` when every posted index has a terminal answer, otherwise how
    /// many do not.
    static func unproven(postedCount: Int, response: HealthKitBatchResponseDTO) -> Int? {
        let open = nonterminalIndexes(postedCount: postedCount, response: response)
        return open.isEmpty ? nil : open.count
    }

    /// The skipped rows of an answer, with the server's reason.
    static func refusals(
        in response: HealthKitBatchResponseDTO,
        posted: [AppleHealthSymptomEntryDTO]
    ) -> [(entry: AppleHealthSymptomEntryDTO, reason: String)] {
        var reasons: [Int: String] = [:]
        for skipped in response.skipped where posted.indices.contains(skipped.index) {
            reasons[skipped.index] = skipped.reason
        }
        for entry in response.entries where posted.indices.contains(entry.index) && entry.status == .skipped {
            reasons[entry.index] = reasons[entry.index] ?? entry.reason ?? "unknown"
        }
        return reasons.keys.sorted().map { (posted[$0], reasons[$0] ?? "unknown") }
    }

    static func nonterminalIndexes(postedCount: Int, response: HealthKitBatchResponseDTO) -> Set<Int> {
        var terminal = Set<Int>()
        for entry in response.entries where (0 ..< postedCount).contains(entry.index) {
            switch entry.status {
            case .inserted, .updated, .duplicate, .skipped: terminal.insert(entry.index)
            default: continue
            }
        }
        for skipped in response.skipped where (0 ..< postedCount).contains(skipped.index) {
            terminal.insert(skipped.index)
        }
        return Set(0 ..< postedCount).subtracting(terminal)
    }
}
