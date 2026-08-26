import Foundation

/// v1.28 (GH iOS #45) — medication-efficacy ("Wirkung") seam on the medications
/// repository.
///
/// Two routes, both server-authoritative:
///   - `GET  /api/medications/{id}/efficacy`        → the resolved efficacy DTO
///   - `PUT  /api/medications/{id}/efficacy/target` → pin / clear the target
///
/// **The read is graceful.** A `404` (route absent on ≤ v1.27 servers) or a
/// `422` maps to `nil` so the detail screen simply omits the section — the
/// feature is *absent*, not *errored*. Standalone mode returns `nil` too (no
/// server ledger, and efficacy leans on the server compliance engine — it is a
/// paired-only surface). Any transport hiccup self-suppresses to `nil`.
///
/// **The write is interactive** (retarget picker): it mints one
/// ``IdempotencyKey`` (PROJECT_GUIDE.md interactive-write convention — the header
/// rides every PUT so a double-tap can't double-apply) and throws on failure so
/// the caller can surface a retry. There is no separate GET for the target: the
/// *current* target is read straight off the efficacy DTO (`resolution` +
/// `targets` + `overrideOptions`), so a set is followed by a re-fetch of
/// `efficacy(...)`.
public extension MedicationsRepository {
    /// Fetches the resolved efficacy view, or `nil` when the feature is absent
    /// (`404`/`422`, standalone, or any transport error). Never throws — the
    /// section self-suppresses on `nil`.
    func efficacy(medicationID: String) async -> MedicationEfficacyDTO? {
        // Paired-only surface: standalone has no server compliance engine.
        if isStandaloneActive { return nil }
        do {
            let req: APIRequest<MedicationEfficacyDTO> = .get(
                "/api/medications/\(medicationID)/efficacy"
            )
            return try await api.send(req)
        } catch let HLError.server(status, _, _) where status == 404 || status == 422 {
            // Route not deployed / rejected → feature absent, section hides.
            return nil
        } catch {
            // Transient transport error → self-suppress; the next refresh retries.
            return nil
        }
    }

    /// Pins (or clears) the efficacy target for a medication. Interactive
    /// write: one idempotency key, throws on failure. The caller re-fetches
    /// ``efficacy(medicationID:)`` on success to pick up the re-resolved view.
    @discardableResult
    func setEfficacyTarget(
        medicationID: String,
        selection: EfficacyTargetSelection,
        primary: Bool? = nil
    ) async throws -> EfficacyTargetResult {
        let body = EfficacyTargetBody(selection: selection, primary: primary)
        let req: APIRequest<EfficacyTargetResult> = try .put(
            "/api/medications/\(medicationID)/efficacy/target",
            body: body,
            idempotencyKey: IdempotencyKey()
        )
        return try await api.send(req)
    }
}
