import Foundation

/// **CU-32 — `GET|POST /api/anamnesis/facts`, `PATCH|DELETE /api/anamnesis/facts/{id}`.**
///
/// Vier Operationen, drei Eigenheiten, die dieser Repository sichtbar macht,
/// statt sie zu glätten:
///
/// 1. **PATCH gibt den Nachfolger zurück, nicht den aktualisierten Vorgänger.**
///    Neue `id`, `provenance == .userCorrection`, `validUntil == nil`. Genau
///    hier geht ein naiver Client-Cache kaputt: wer die Antwort auf die alte ID
///    zurückschreibt, hält danach ein totes Token. Deshalb reicht dieser
///    Repository die Antwort unverändert durch und der Store lädt neu.
/// 2. **Die Revisions-ID im Pfad ist das Nebenläufigkeits-Token.** Kein
///    `baseUpdatedAt`, kein `If-Match`, kein `OptimisticWriteBody` — anders als
///    bei den Lock-Routen. Ein zusätzlicher Schlüssel im PATCH-Body würde vom
///    Server ohnehin verworfen.
/// 3. **POST liegt unter einem Idempotenz-Wrapper**, dessen 409 `error` als
///    Objekt sendet. Lesbar wird das erst durch die tolerante
///    `APIEnvelope`-Dekodierung; hier wird es zu
///    ``AnamnesisFactFailure/requestInFlight``.
///
/// Jede Methode wirft ``AnamnesisFactFailure`` — nie einen rohen ``HLError``.
/// Das ist der Punkt, an dem aus einem Statuscode ein Sachverhalt wird.
///
/// **Kein Outbox-Pfad, bewusst.** Die drei Fakten sind eine seltene, manuelle
/// Angabe in einer Detail-Fläche; ein blind wiedergespieltes POST würde beim
/// Replay auf `currentExists` laufen, sobald der Nutzer den Wert zwischenzeitlich
/// erneut gesetzt hat. Ein fehlgeschlagener Schreibvorgang bleibt deshalb
/// sichtbar am Formular stehen, statt still in eine Warteschlange zu wandern.
/// Der Idempotency-Key wird trotzdem gesetzt (Pflicht auf jedem POST/PATCH) und
/// deckt den Netzwerk-Retry innerhalb desselben Requests ab.
public actor AnamnesisRepository {
    private let api: APIClientProtocol

    public init(api: APIClientProtocol) {
        self.api = api
    }

    private static let basePath = "/api/anamnesis/facts"

    // MARK: - Read

    /// Aktueller Stand aller drei Arten plus vollständiger Verlauf.
    /// `current` trägt serverseitig immer alle drei Schlüssel (ggf. `null`);
    /// `history` ist ungefiltert und unpaginiert.
    public func facts() async throws -> AnamnesisFactsPayload {
        try await mapping {
            let request: APIRequest<AnamnesisFactsPayload> = .get(Self.basePath)
            return try await api.send(request)
        }
    }

    // MARK: - Write

    /// Legt den **ersten** Wert einer Art an. Existiert bereits eine aktuelle
    /// Revision, antwortet der Server mit ``AnamnesisFactFailure/currentExists``
    /// — dann ist ``correct(revisionId:to:)`` der richtige Weg.
    ///
    /// Wirft ``AnamnesisFactFailure/invalidValue`` **ohne** Netzwerk-Runde,
    /// wenn der Wert nicht zur Art gehört: der POST ist eine diskriminierte
    /// Union, ein `{kind: SMOKING_STATUS, value: ROTATING}` ist per Definition
    /// ein 422 — den müssen wir nicht erst beim Server einsammeln.
    @discardableResult
    public func create(kind: AnamnesisFactKind, value: AnamnesisFactValue) async throws -> AnamnesisFactRevision {
        guard kind.allows(value) else { throw AnamnesisFactFailure.invalidValue }
        return try await mapping {
            let request: APIRequest<AnamnesisFactRevision> = try .post(
                Self.basePath,
                body: AnamnesisFactCreate(kind: kind, value: value)
            )
            return try await api.send(request)
        }
    }

    /// Korrigiert eine bestehende Revision. `revisionId` **ist** das
    /// optimistische Token; der Body trägt nur `{ value }`.
    ///
    /// Zurück kommt der **Nachfolger** (neue `id`, `provenance ==
    /// .userCorrection`), nicht die aktualisierte Ursprungszeile.
    ///
    /// `kind` dient allein der lokalen Vorabprüfung — gesendet wird sie nicht,
    /// der Server liest die Art aus der gespeicherten Zeile.
    @discardableResult
    public func correct(
        revisionId: String,
        kind: AnamnesisFactKind,
        to value: AnamnesisFactValue
    ) async throws -> AnamnesisFactRevision {
        guard kind.allows(value) else { throw AnamnesisFactFailure.invalidValue }
        return try await mapping {
            let request: APIRequest<AnamnesisFactRevision> = try .patch(
                "\(Self.basePath)/\(revisionId)",
                body: AnamnesisFactCorrection(value: value)
            )
            return try await api.send(request)
        }
    }

    /// Schliesst die aktuelle Revision (setzt `validUntil`), ohne einen
    /// Nachfolger anzulegen — die Art ist danach wieder „nie erfasst"-artig
    /// ohne aktuellen Wert. Antwort ist 200 mit einer kleineren Shape **ohne**
    /// `value`.
    @discardableResult
    public func remove(revisionId: String) async throws -> RemovedAnamnesisFact {
        try await mapping {
            let request: APIRequest<RemovedAnamnesisFact> = .delete("\(Self.basePath)/\(revisionId)")
            return try await api.send(request)
        }
    }

    // MARK: - Error mapping

    /// Führt `work` aus und übersetzt jeden geworfenen Fehler in ein
    /// ``AnamnesisFactFailure``. ``AnamnesisFactFailure/from(_:)`` ist
    /// idempotent, ein bereits übersetztes Failure bleibt also unverändert.
    private func mapping<T: Sendable>(_ work: () async throws -> T) async throws -> T {
        do {
            return try await work()
        } catch {
            throw AnamnesisFactFailure.from(error)
        }
    }
}
