import Foundation

/// **AUDITC (1.5.0)** — AUDIT-C on the life-circumstances store.
///
/// The store keeps what the read route delivered; the form's own state (the
/// chosen answers, the retry identity, the removal question) lives in
/// ``AuditCModel`` beside the screen. Both writes reload the page afterwards,
/// so the sum, the verdict and the history on screen are always the server's.
extension LifeCircumstancesStore {
    /// AUDIT-C as the last read delivered it; `nil` on a server without it.
    var auditC: LifeAuditC? {
        payload?.auditC
    }

    /// Sends the answers, then reloads. Throws the raw ``HLError``.
    func submitAuditC(_ submission: AuditCSubmission) async throws -> AuditCResult {
        let result = try await repo.submitAuditC(submission)
        await load()
        return result
    }

    /// Removes one entry, then reloads. A refused or failed removal reloads
    /// too, so an entry that is already gone does not linger on screen.
    func removeAuditC(id: String) async throws {
        do {
            try await repo.removeAuditC(id: id)
        } catch {
            await load()
            throw error
        }
        await load()
    }

    // MARK: - The earlier one-word answer (POLISH-C, C7)

    /// Reads `ALCOHOL_PATTERN` from `GET /api/anamnesis/facts`, as the web's
    /// alcohol section does. Only where the page has AUDIT-C: on an older
    /// server the answer stays where it always was (About me, Anamnesis). A
    /// failed read shows no row and leaves the page as it is.
    func loadLegacyAlcohol() async {
        guard payload?.auditC != nil else {
            legacyAlcohol = nil
            return
        }
        let facts = try? await AnamnesisRepository(api: repo.api).facts()
        legacyAlcohol = facts.flatMap(Self.legacyAlcohol(in:))
    }

    /// The current `ALCOHOL_PATTERN` revision with a value this build can
    /// name; `nil` for none, an unreadable one or an unknown literal.
    nonisolated static func legacyAlcohol(in facts: AnamnesisFactsPayload) -> AnamnesisFactRevision? {
        guard case let .recorded(revision, value) = facts.state(for: .alcoholPattern), !value.isUnknown else { return nil }
        return revision
    }

    /// Removes the earlier answer, then reloads. AUDIT-C entries stay.
    func removeLegacyAlcohol() async throws {
        guard let legacyAlcohol else { return }
        do {
            try await AnamnesisRepository(api: repo.api).remove(revisionId: legacyAlcohol.id)
        } catch {
            await load()
            throw error
        }
        await load()
    }
}
