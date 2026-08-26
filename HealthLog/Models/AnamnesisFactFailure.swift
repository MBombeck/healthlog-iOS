import Foundation

/// **CU-32 — die Fehlerbilder der Anamnese-Fläche, benannt statt generisch.**
///
/// Diese Fläche hat vier Fehlschläge, die für den Menschen davor vier
/// verschiedene Dinge bedeuten und vier verschiedene Auswege haben. Sie alle in
/// ein „Es ist ein Fehler aufgetreten" zu kippen wäre genau die Sorte
/// Unehrlichkeit, die diese Fläche nicht verträgt — deshalb übersetzt der
/// Repository sie hier in benannte Fälle, und der Store bildet jeden auf eine
/// eigene Erklärung ab.
///
/// **Warum 404 hier ein Nebenläufigkeits-Fehler ist:** die Route prüft die ID
/// im Pfad gegen `id ∧ userId ∧ validUntil IS NULL ∧ supersededByRevisionId IS
/// NULL`. Eine ID, die durch eine parallele Korrektur abgelöst wurde, erfüllt
/// (c)/(d) nicht mehr und gibt **404, nicht 409**. Für uns ist das derselbe
/// Ausweg wie beim 409: neu laden, frische ID nehmen.
public enum AnamnesisFactFailure: Error, Sendable, Equatable {
    /// **409 `anamnesis.fact.conflict`** — zwischen Torwächter und bewachtem
    /// Update hat ein nebenläufiger Request die Zeile geschlossen. Kein
    /// Schreibvorgang, kein Audit-Eintrag. Der 409-Body enthält die neue ID
    /// **nicht** — es gibt nichts, was der Client daraus rekonstruieren könnte.
    case conflict
    /// **404** — die Revisions-ID ist nicht (mehr) die aktuelle. Von einer
    /// fremden ID nicht unterscheidbar, und das ist Absicht.
    case staleRevision
    /// **422 `anamnesis.fact.invalidValue`** (oder ein Zod-422 auf demselben
    /// Body) — der Wert passt nicht zur Art. Sollte uns nie erreichen, weil
    /// ``AnamnesisFactKind/allows(_:)`` vorher prüft; erreicht er uns doch, hat
    /// der Server seine Wertemenge geändert.
    case invalidValue
    /// **409 `anamnesis.fact.currentExists`** — es gibt bereits einen aktuellen
    /// Wert dieser Art, POST ist der falsche Verb. Kann auch aus dem zweiten
    /// Unique-Index `(user_id, kind, valid_from)` stammen (zwei POSTs in
    /// derselben Millisekunde); die Reaktion ist in beiden Fällen dieselbe.
    case currentExists
    /// **409 aus dem Idempotenz-Wrapper** (nur POST): eine Anfrage mit
    /// demselben `Idempotency-Key` läuft bereits. Dieser 409 sendet `error` als
    /// **Objekt** statt als String — abweichend vom sonstigen Envelope; er wird
    /// erst durch die tolerante `APIEnvelope`-Dekodierung überhaupt lesbar und
    /// trägt kein `meta.errorCode`.
    case requestInFlight
    /// Alles andere — Transport, Auth, 5xx. Trägt den ursprünglichen Fehler,
    /// damit der Store dessen `userFacingDescription` benutzen kann.
    case other(HLError)

    /// Errorcode-Literale des Servers. Einzige Stelle, an der sie stehen.
    public enum Code {
        public static let conflict = "anamnesis.fact.conflict"
        public static let invalidValue = "anamnesis.fact.invalidValue"
        public static let currentExists = "anamnesis.fact.currentExists"
    }

    /// Übersetzt einen geworfenen Fehler in das Fehlerbild dieser Fläche.
    ///
    /// **Idempotent.** Ein bereits übersetztes Failure kommt unverändert zurück
    /// — sonst fiele es beim zweiten Durchlauf (Repository wirft, Store
    /// übersetzt erneut) durch den `as? HLError`-Torwächter und landete als
    /// ``other(_:)`` mit generischem Text. Genau das hat der Store-Test
    /// gefangen.
    public static func from(_ error: Error) -> AnamnesisFactFailure {
        if let failure = error as? AnamnesisFactFailure {
            return failure
        }
        guard let hlError = error as? HLError else {
            return .other(.unknown(String(describing: error)))
        }
        guard case let .server(status, code, _) = hlError else {
            return .other(hlError)
        }
        switch (status, code) {
        case (409, Code.conflict):
            return .conflict
        case (409, Code.currentExists):
            return .currentExists
        case (409, nil):
            // Der Idempotenz-Wrapper ist die einzige 409-Quelle auf diesen
            // Routen ohne `meta.errorCode` — die beiden fachlichen 409er
            // tragen ihn immer.
            return .requestInFlight
        case (422, _):
            // Beide 422-Formen (errorCode-ohne-`details` und Zod-mit-`details`)
            // sagen dasselbe: der gesendete Wert wurde nicht angenommen.
            return .invalidValue
        case (404, _):
            return .staleRevision
        default:
            return .other(hlError)
        }
    }

    /// `true`, wenn der Ausweg „neu laden und noch einmal" ist — der Store
    /// zieht danach automatisch einen frischen `GET`, weil die alte
    /// Revisions-ID als Token tot ist.
    public var requiresReload: Bool {
        switch self {
        case .conflict, .staleRevision, .currentExists: true
        case .invalidValue, .requestInFlight, .other: false
        }
    }

    /// Die Erklärung, die der Mensch davor liest. Bewusst je Fall eigen —
    /// „Es ist ein Fehler aufgetreten" wäre hier eine Lüge über vier
    /// verschiedene Sachverhalte.
    public var userFacingDescription: String {
        switch self {
        case .conflict:
            String(localized: "anamnesis.error.conflict")
        case .staleRevision:
            String(localized: "anamnesis.error.stale")
        case .invalidValue:
            String(localized: "anamnesis.error.invalidValue")
        case .currentExists:
            String(localized: "anamnesis.error.currentExists")
        case .requestInFlight:
            String(localized: "anamnesis.error.inFlight")
        case let .other(hlError):
            hlError.userFacingDescription
        }
    }
}
