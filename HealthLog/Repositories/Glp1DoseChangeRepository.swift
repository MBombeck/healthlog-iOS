import Foundation

/// **#169 (server 1.48.0) — GLP-1 titration steps on the server, and the
/// site of a recorded dose.**
///
/// Contracts consumed:
///   create: `POST /api/medications/[id]/glp1` with `{ doseChange: { effectiveFrom,
///           doseValue, doseUnit, note?, clientId? } }` → `{ doseChange }`, 201 when
///           written, 200 when `clientId` names a step the server already holds,
///           410 `glp1.doseChange.deleted` when that step was removed since.
///   edit:   `PATCH /api/medications/[id]/glp1/dose-changes/[doseChangeId]`
///           (every field optional, `note: null` clears) → `{ doseChange }`.
///   remove: `DELETE` on the same path → `{ id, deleted }`.
///   site:   `PUT /api/medications/[id]/intake/[eventId]` with `injectionSite`
///           (through ``MedicationsRepository/updateIntake(medicationId:eventId:patch:)``).
///
/// **Why the create has no outbox row of its own.** A step is written on the
/// device first and waits there, unmarked, until a create answers. That local
/// row is the durable queue: every load of the ladder sends the unmarked rows
/// again, under the step's own id as `clientId`, and the server answers a
/// repeat with the stored step. So a lost answer, two devices holding the same
/// step, or a crash between send and mark all end in one server row. Each
/// request still carries an `Idempotency-Key`. Edit and remove act on a step
/// the server already holds and answer the person directly.
public actor Glp1DoseChangeRepository {
    let api: APIClientProtocol
    let encoder: JSONEncoder
    /// The intake edit the site rides on; `nil` keeps site writes off.
    let medications: MedicationsRepository?

    public init(
        api: APIClientProtocol,
        medications: MedicationsRepository? = nil,
        encoder: JSONEncoder = .hlDefault
    ) {
        self.api = api
        self.medications = medications
        self.encoder = encoder
    }

    // MARK: - Titration steps

    /// Uploads one step. A 200 for a step the server already holds answers
    /// exactly like a fresh create. A 410 throws ``HLError/server(status:code:message:)``
    /// with ``Glp1DoseChangeWire/deletedErrorCode``; see ``HLError/isGlp1DoseChangeDeleted``.
    public func create(medicationID: String, step: Glp1DoseChangeCreate) async throws -> Glp1DoseChangeDTO {
        let req: APIRequest<Glp1DoseChangeEnvelope> = try .post(
            "/api/medications/\(medicationID)/glp1",
            body: Glp1DoseChangeCreateBody(doseChange: step),
            encoder: encoder
        )
        return try await api.send(req).doseChange
    }

    /// Corrects a step the server holds.
    public func update(
        medicationID: String,
        doseChangeID: String,
        patch: Glp1DoseChangePatch
    ) async throws -> Glp1DoseChangeDTO {
        let req: APIRequest<Glp1DoseChangeEnvelope> = try .patch(
            "/api/medications/\(medicationID)/glp1/dose-changes/\(doseChangeID)",
            body: patch,
            encoder: encoder
        )
        return try await api.send(req).doseChange
    }

    /// Removes a step the server holds. A step already gone (404) counts as
    /// removed.
    public func delete(medicationID: String, doseChangeID: String) async throws {
        let req: APIRequest<MedicationMutationAck> = .delete(
            "/api/medications/\(medicationID)/glp1/dose-changes/\(doseChangeID)"
        )
        do {
            _ = try await api.send(req)
        } catch let HLError.server(status, _, _) where status == 404 {
            return
        }
    }

    /// **#191 (server 1.49.0) — removes a step by the device's own id.**
    /// `DELETE /api/medications/[id]/glp1/dose-changes?clientId=…` removes the
    /// step under that `clientId` if the server holds one and spends the id
    /// either way (a later create with it answers 410). Always 204, so it is
    /// safe to repeat. Used when a step is deleted on the device while its
    /// upload may still be on the way.
    public func delete(medicationID: String, clientId: String) async throws {
        let req = APIRequest<EmptyResponse>(
            method: .delete,
            path: "/api/medications/\(medicationID)/glp1/dose-changes",
            query: [("clientId", clientId)]
        )
        _ = try await api.send(req)
    }

    // MARK: - Site of a recorded dose

    /// Sets (`site`) or clears (`nil`) the injection site of a recorded dose.
    /// A retriable failure waits in the outbox like every intake edit; a 422
    /// `medications.intake.injection_site.disallowed` is final and is thrown
    /// without a queued row (``HLError/isInjectionSiteDisallowed``).
    @discardableResult
    public func setInjectionSite(
        medicationID: String,
        intakeID: String,
        site: InjectionSite?
    ) async throws -> MedicationIntake {
        guard let medications else { throw HLError.serverNotConfigured }
        return try await medications.updateIntake(
            medicationId: medicationID,
            eventId: intakeID,
            patch: Self.sitePatch(site)
        )
    }

    /// The intake edit for a site: the server's enum string, or an explicit
    /// `null` to clear. A site this build cannot name is never written.
    static func sitePatch(_ site: InjectionSite?) throws -> MedicationsRepository.IntakePatch {
        guard let site else { return MedicationsRepository.IntakePatch(injectionSite: .null) }
        guard let raw = site.serverRawValue else { throw HLError.unknown("injection site without a server value") }
        return MedicationsRepository.IntakePatch(injectionSite: .value(raw))
    }
}

// MARK: - Wire shapes

/// Namespace for the #169 error codes.
public enum Glp1DoseChangeWire {
    /// 410 on a create whose `clientId` names a step removed since.
    public static let deletedErrorCode = "glp1.doseChange.deleted"
    /// 422 on an intake edit with a site the medication does not allow.
    public static let siteDisallowedErrorCode = "medications.intake.injection_site.disallowed"
}

/// The `doseChange` arm of `glp1PostBodySchema`.
public struct Glp1DoseChangeCreate: Codable, Sendable, Equatable {
    public let effectiveFrom: Date
    public let doseValue: Double
    public let doseUnit: String
    public let note: String?
    /// The device's own id of the step: 1 to 128 of `A-Z a-z 0-9 . _ : -`.
    public let clientId: String

    public init(effectiveFrom: Date, doseValue: Double, doseUnit: String = "mg", note: String?, clientId: String) {
        self.effectiveFrom = effectiveFrom
        self.doseValue = doseValue
        self.doseUnit = doseUnit
        self.note = note
        self.clientId = clientId
    }

    enum CodingKeys: String, CodingKey {
        case effectiveFrom, doseValue, doseUnit, note, clientId
    }

    /// A missing note is left out rather than sent as `null`.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(effectiveFrom, forKey: .effectiveFrom)
        try container.encode(doseValue, forKey: .doseValue)
        try container.encode(doseUnit, forKey: .doseUnit)
        try container.encodeIfPresent(note, forKey: .note)
        try container.encode(clientId, forKey: .clientId)
    }
}

struct Glp1DoseChangeCreateBody: Encodable, Sendable {
    let doseChange: Glp1DoseChangeCreate
}

/// `glp1DoseChangePatchSchema`: every field optional, `note: null` clears.
public struct Glp1DoseChangePatch: Encodable, Sendable, Equatable {
    public let effectiveFrom: Date?
    public let doseValue: Double?
    public let doseUnit: String?
    public let note: MedicationsRepository.PatchField<String>

    public init(
        effectiveFrom: Date? = nil,
        doseValue: Double? = nil,
        doseUnit: String? = nil,
        note: MedicationsRepository.PatchField<String> = .absent
    ) {
        self.effectiveFrom = effectiveFrom
        self.doseValue = doseValue
        self.doseUnit = doseUnit
        self.note = note
    }

    enum CodingKeys: String, CodingKey {
        case effectiveFrom, doseValue, doseUnit, note
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(effectiveFrom, forKey: .effectiveFrom)
        try container.encodeIfPresent(doseValue, forKey: .doseValue)
        try container.encodeIfPresent(doseUnit, forKey: .doseUnit)
        switch note {
        case .absent: break
        case .null: try container.encodeNil(forKey: .note)
        case let .value(text): try container.encode(text, forKey: .note)
        }
    }
}

/// `{ doseChange: { … } }`, the answer of create and edit.
struct Glp1DoseChangeEnvelope: Decodable, Sendable {
    let doseChange: Glp1DoseChangeDTO
}

public extension HLError {
    /// 410: the step was removed on the server; the local copy goes for good.
    var isGlp1DoseChangeDeleted: Bool {
        if case .server(410, Glp1DoseChangeWire.deletedErrorCode, _) = self { return true }
        return false
    }

    /// 422: the medication does not take this site. Final, never retried.
    var isInjectionSiteDisallowed: Bool {
        if case .server(422, Glp1DoseChangeWire.siteDisallowedErrorCode, _) = self { return true }
        return false
    }
}
