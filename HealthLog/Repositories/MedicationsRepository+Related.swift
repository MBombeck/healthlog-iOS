import Foundation

/// **RELATED (1.5.0, #141) — the single-medication read.**
///
/// `GET /api/medications/{id}` answers with the full `MedicationDetail`, which
/// since server v1.43 carries `related` (lab results, documents, episodes, …
/// resolved on the server). The list does not, so the detail screen reads the
/// one medication for its "Related" section. A plain read: nothing is queued,
/// a failure is thrown to the caller.
public extension MedicationsRepository {
    func medication(id: String) async throws -> Medication {
        let req: APIRequest<MedicationWireDTO> = .get("/api/medications/\(id)")
        return try await api.send(req).toDomain()
    }
}
