import Foundation

// Die Quellen-Achse des Mess-Wire-Formats: das Server-Enum
// (`measurementSourceEnum` in `src/lib/validations/measurement.ts`) und die
// beiden Abbildungen auf das Domain-Enum.
//
// Eigene Datei, weil `MeasurementDTO.swift` an der 1000-Zeilen-Fehlergrenze
// steht und jeder neue Quellenwert vier Stellen hier wachsen lässt. Reine
// Verschiebung — kein Verhalten hängt am Split.
//
// **Der teure Fehler an dieser Achse:** das Enum hat keinen Unbekannt-Fall,
// also wirft ein unbekannter Rohwert im Element und der tolerante
// List-Decoder verwirft die ganze Zeile — still. Der Mess-Zähler weicht dann
// vom Server ab, ohne dass irgendwo ein Fehler auftaucht. Das ist bisher bei
// WHOOP, GOOGLE_HEALTH, COMPUTED (#42) und STRAVA/OURA/POLAR/NIGHTSCOUT (#46)
// passiert. `MeasurementSourceWireTests` nagelt jeden Fall fest.

public enum ServerMeasurementSource: String, Codable, Sendable, CaseIterable {
    case manual = "MANUAL"
    /// Server-Schema (`measurementSourceEnum`) verwendet `APPLE_HEALTH`. Früher
    /// `HEALTHKIT` — diese Wire-Form rejected der Server seit v1.4.x mit 422.
    case appleHealth = "APPLE_HEALTH"
    case withings = "WITHINGS"
    /// Server-owned read-only ingest (BYO-key OAuth, v1.11.5). Ohne diesen Case
    /// droppt der tolerante List-Decoder jede WHOOP-Zeile still → Mess-Count
    /// divergiert vom Server.
    case whoop = "WHOOP"
    /// Google-Health-/Fitbit-Provider (v1.12.0). Exakte Wire-Schreibweise —
    /// Drift = stiller Decode-Drop (siehe `v1.12.0-server-to-ios-fitbit-source-heads-up`).
    case fitbit = "FITBIT"
    /// Google-Health-API-Provider (Server v1.27.0, Issue #401). Liest Fitbit/
    /// Pixel-Watch-Daten über den Google-Account; läuft NEBEN dem klassischen
    /// `FITBIT`-Provider. Server-owned read-only — der Server nimmt die Source
    /// auf keinem Client-Write-Pfad an. Ohne diesen Case droppt der tolerante
    /// List-Decoder jede GOOGLE_HEALTH-Zeile still → Mess-Count divergiert.
    case googleHealth = "GOOGLE_HEALTH"
    /// Server-derived rows (Read-Enum seit v1.10). Seit v1.27.6 tragen Screening-
    /// Summenscores (PHQ-9 / GAD-7 / WHO-5) diese Source statt `MANUAL` (Migration
    /// 0225). Server-owned read-only — kein Client-Write-Pfad. Ohne diesen Case
    /// droppt der tolerante List-Decoder jede COMPUTED-Zeile still (gleiche
    /// Failure-Mode wie GOOGLE_HEALTH, #40) → die Screening-Zeilen verschwinden.
    case computed = "COMPUTED"
    /// Strava-Provider (Server v1.28.11, iOS #46). Read-only Workout-/Aktivitäts-
    /// Ingest — trägt auf Workout-Rows (`GET /api/sync/changes`, `GET
    /// /api/workouts`) und mit-attribuierten Measurement-Rows. Server-owned, kein
    /// Client-Write-Pfad (nicht in `WRITABLE_MEASUREMENT_SOURCES`). Ohne diesen
    /// Case droppt der tolerante List-Decoder jede STRAVA-Zeile still (gleiche
    /// Failure-Mode wie GOOGLE_HEALTH, #40).
    case strava = "STRAVA"
    /// Oura-Ring-Provider. Die App shippt bereits eine Oura-Integration
    /// (`ouraIntegrationStore`). Server-owned read-only ingest (Recovery/Sleep/
    /// HR). Kein Client-Write-Pfad. Exakte Wire-Schreibweise — Drift = stiller
    /// Decode-Drop.
    case oura = "OURA"
    /// Polar-Provider. Die App shippt bereits eine Polar-Integration
    /// (`polarIntegrationStore`). Server-owned read-only ingest (Cardio-Load/
    /// ANS-Charge/HR). Kein Client-Write-Pfad.
    case polar = "POLAR"
    /// Nightscout-Provider. Die App shippt bereits eine Nightscout-Integration
    /// (`nightscoutIntegrationStore`). Server-owned read-only ingest (CGM-Glukose).
    /// Kein Client-Write-Pfad.
    case nightscout = "NIGHTSCOUT"
    /// Numerische Antwort auf eine Telegram-Erinnerung (Server v1.19.2,
    /// `src/lib/validations/measurement.ts:204`). Der Wert wird aus dem
    /// chat-gebundenen Webhook geschrieben, nicht über den Client-Write-Pfad —
    /// deshalb steht `TELEGRAM` nicht in `WRITABLE_MEASUREMENT_SOURCES`. Ohne
    /// diesen Case droppt der tolerante List-Decoder jede TELEGRAM-Zeile still.
    case telegram = "TELEGRAM"
    /// Messwerte, die über die bestätigte MCP-Write-Fläche unter einem
    /// `health:write`-Token gelandet sind (Server v1.22.0,
    /// `src/lib/validations/measurement.ts:211`). In-Prozess geschrieben, nie
    /// über den Cookie-/Bearer-Client-Pfad — nicht in
    /// `WRITABLE_MEASUREMENT_SOURCES`. Ohne diesen Case droppt der tolerante
    /// List-Decoder jede MCP-Zeile still.
    case mcp = "MCP"
    /// Zeilen, die über ein Ingest-Bearer-Token geschrieben wurden (Home-
    /// Assistant-Bridges, Waagen-Skripte) — Server v1.37.x, Issue #106 /
    /// Server-PR #892. Server-owned read-only: `EXTERNAL` steht nicht in
    /// `WRITABLE_MEASUREMENT_SOURCES`, der Server weist eine client-genannte
    /// Source auf dem Ingest-Pfad mit `measurement.batch.source_not_permitted`
    /// ab. Kein Client-Write-Pfad. Ohne diesen Case droppt der tolerante
    /// List-Decoder jede EXTERNAL-Zeile still (gleiche Failure-Mode wie
    /// COMPUTED #42 und STRAVA/OURA/POLAR/NIGHTSCOUT #46).
    case external = "EXTERNAL"
    case import_ = "IMPORT"
    /// Audit B-4 — a `MeasurementSource` this build does not know.
    ///
    /// The raw value is a token the server's SCREAMING_SNAKE vocabulary cannot
    /// produce; only the tolerant `init(from:)` in
    /// `MeasurementDTO+UnknownType.swift` puts a row here, and `encode(to:)`
    /// refuses to put it back. Four releases running, a source the server had
    /// already shipped cost every row that carried it — this is the arm that
    /// ends that pattern.
    case unknown = "__UNKNOWN__"
}

public extension ServerMeasurementSource {
    /// One arm per wire value — the exhaustive switch IS the contract, so the
    /// complexity grows by one with every source the server adds.
    func toDomain() -> MeasurementSource { // swiftlint:disable:this cyclomatic_complexity
        switch self {
        case .manual: .manual
        case .appleHealth: .appleHealth
        case .withings: .withings
        case .whoop: .whoop
        case .fitbit: .fitbit
        case .googleHealth: .googleHealth
        case .computed: .computed
        case .strava: .strava
        case .oura: .oura
        case .polar: .polar
        case .nightscout: .nightscout
        case .telegram: .telegram
        case .mcp: .mcp
        case .external: .external
        case .import_: .import_
        // Audit B-4 — a source this build does not know.
        case .unknown: .unknown
        }
    }
}

public extension MeasurementSource {
    var wire: ServerMeasurementSource {
        switch self {
        case .manual: .manual
        case .appleHealth: .appleHealth
        case .withings: .withings
        case .whoop: .whoop
        case .fitbit: .fitbit
        case .googleHealth: .googleHealth
        case .computed: .computed
        case .strava: .strava
        case .oura: .oura
        case .polar: .polar
        case .nightscout: .nightscout
        case .telegram: .telegram
        case .mcp: .mcp
        case .external: .external
        case .import_: .import_
        case .unknown: .unknown
        }
    }
}
