import Foundation

/// Treiber für die HealthKit-Permission-Picker-Gruppierung + jede andere
/// UI, die `MeasurementType`-Werte nach UI-Buckets ordnen will. Quelle der
/// Wahrheit ist der Server (`GET /api/measurement-categories`, seit
/// `v1.4.30.1`) — `R1` der CROSS-COORDINATION-AUDIT bevorzugt diese
/// HTTP-Projektion gegenüber einem hartcodierten Spiegel, damit ein
/// zukünftiges Hinzufügen einer Kategorie nur am Server passiert und
/// alte Builds graceful den Fallback weiterbenutzen.
///
/// **Cache-Strategie:**
/// - In-Memory-TTL von 10 Minuten passt zum `Cache-Control: public,
///   max-age=600`, das der Server bereits setzt — kein Doppel-Cache.
/// - Reload außerhalb des TTL ist transparent: nächste `categoryMap()`-
///   Anfrage triggert einen Refresh-Roundtrip, fällt bei Fehler auf den
///   letzten erfolgreichen Snapshot zurück, dann auf den hartcodierten
///   Fallback (`CategoryAssignmentMap.bundledFallback`).
/// - Cold-Start ohne Netz: hartcodierter Fallback rendert sofort, ein
///   späterer Online-Tick frischt auf. Picker-UX hat damit keinen
///   "Wartet auf Server"-Stutter.
///
/// **Architektur:** Repository = Actor (Network-Touchpoint), Domain-Map
/// = `Sendable` + `Codable`, keine `@MainActor`-Coupling. Konsumenten
/// (Picker-View / Settings-Liste) hopen auf `@MainActor` via Store, der
/// die Map einmalig cached.
public actor MeasurementCategoriesRepository {
    private let api: APIClientProtocol
    private let cacheTTL: TimeInterval
    private let clock: @Sendable () -> Date

    /// Letzte erfolgreich vom Server geholte Snapshot. `nil` solange noch
    /// kein Online-Hit gelungen ist; dann liefert `categoryMap()` den
    /// hartcodierten Fallback aus.
    private var cached: CategoryAssignmentMap?
    /// Wann der `cached`-Snapshot reingekommen ist (für TTL-Check).
    private var cachedAt: Date?

    public init(
        api: APIClientProtocol,
        cacheTTL: TimeInterval = 600,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.api = api
        self.cacheTTL = cacheTTL
        self.clock = clock
    }

    // MARK: - Public surface

    /// Liefert die aktuell beste verfügbare Kategorisierung. Reihenfolge:
    ///
    ///   1. Server-Hit innerhalb des TTL → zurückgeben.
    ///   2. Server-Hit außerhalb des TTL → refreshen, bei Fehler
    ///      den abgelaufenen Snapshot zurückgeben (Stale-While-Revalidate).
    ///   3. Noch nie online gewesen → `bundledFallback`.
    ///
    /// **Wirft nie:** Die Map ist UI-Driving, ein leerer Fallback wäre
    /// schlechter als der hartcodierte. Netz-/Decoding-Fehler werden
    /// geloggt + geschluckt; das Repository ist nicht der richtige Ort,
    /// User-facing-Fehlerflows zu eskalieren.
    public func categoryMap() async -> CategoryAssignmentMap {
        if let cached, let cachedAt, clock().timeIntervalSince(cachedAt) < cacheTTL {
            return cached
        }
        do {
            let payload = try await fetchFromServer()
            cached = payload
            cachedAt = clock()
            return payload
        } catch {
            HLLog.api
                .warning("MeasurementCategoriesRepository fetch failed; falling back: \(error.localizedDescription, privacy: .private)")
            return cached ?? CategoryAssignmentMap.bundledFallback
        }
    }

    /// Test-Hook: Cache invalidieren, sodass der nächste `categoryMap()`
    /// einen frischen Roundtrip macht.
    public func invalidateCache() {
        cached = nil
        cachedAt = nil
    }

    /// Test-Hook: ist die aktuelle Antwort aus dem Cache (true) oder aus
    /// dem Fallback (false)? `nil` solange noch nichts geholt wurde.
    public var cacheState: Bool? {
        cached != nil
    }

    // MARK: - Internals

    private func fetchFromServer() async throws -> CategoryAssignmentMap {
        let req: APIRequest<CategoryAssignmentMap> = .get("/api/measurement-categories")
        return try await api.send(req)
    }
}

// MARK: - Wire shape

/// Wire-Form von `GET /api/measurement-categories`. Server-Source:
/// `src/app/api/measurement-categories/route.ts`. Server liefert das
/// `{data, error}`-Envelope, der `APIClient` packt automatisch aus, so
/// dass wir hier nur den inneren Payload sehen.
///
/// **Versionierung:** `version: 1` ist additiv — neue MeasurementTypes
/// landen in `assignments`, neue Kategorien in `categories[]`. Reshuffles
/// existierender Zuordnungen wären ein Breaking-Change und werden vom
/// Server-Brief explizit als "never" markiert (§4 Categorisation overlay).
public struct CategoryAssignmentMap: Codable, Sendable, Equatable {
    /// Additiver Versions-Marker. Aktuell `1`.
    public let version: Int
    /// Sortierte Kategorie-Definitionen für die Picker-Layouts.
    public let categories: [Category]
    /// `MeasurementType.rawValue` (SCREAMING_SNAKE_CASE) → category-id.
    /// Strings statt typed `ServerMeasurementType` an dieser Stelle, weil
    /// der Server schon Werte enthält, die iOS noch nicht kennt
    /// (HRV, RESTING_HEART_RATE, …); die unbekannten Keys ignorieren wir
    /// einfach, statt das ganze Mapping über JSON-Decoding zu verlieren.
    public let assignments: [String: String]

    public init(version: Int, categories: [Category], assignments: [String: String]) {
        self.version = version
        self.categories = categories
        self.assignments = assignments
    }

    /// Eine einzelne Kategorie-Definition. `labelKey` ist ein
    /// `Localizable.xcstrings`-Key (z. B. `"categories.vitals"`); iOS
    /// resolvet ihn UI-seitig via `LocalizedStringResource`. `order`
    /// ist die Anzeige-Reihenfolge.
    public struct Category: Codable, Sendable, Equatable, Identifiable {
        public let id: String
        public let labelKey: String
        public let order: Int

        public init(id: String, labelKey: String, order: Int) {
            self.id = id
            self.labelKey = labelKey
            self.order = order
        }
    }

    // MARK: - Lookup helpers

    /// Welcher Bucket für diesen wire-MeasurementType? `nil` heißt der
    /// Server kennt den Type, hat aber kein Mapping (sollte nicht
    /// passieren); für unbekannte Strings ebenfalls `nil`.
    public func categoryId(forRawType raw: String) -> String? {
        assignments[raw]
    }

    /// Sortiert nach `order` — UI iteriert direkt drüber.
    public var orderedCategories: [Category] {
        categories.sorted { $0.order < $1.order }
    }

    /// Liste aller bekannten wire-Types in einem Bucket, in beliebiger
    /// (aber deterministischer) Reihenfolge — Picker-Layout sortiert
    /// danach selbst.
    public func rawTypes(in categoryId: String) -> [String] {
        assignments
            .filter { $0.value == categoryId }
            .map(\.key)
            .sorted()
    }

    // MARK: - Bundled offline fallback

    /// Hartcodierter Spiegel von `src/lib/measurements/categories.ts`
    /// (Stand `v1.4.30.1`). Wird gerendert, bevor der erste Server-Hit
    /// landet — z.B. beim ersten Onboarding-Schritt, wenn HealthKit-
    /// Authorization gerade gefragt wird und das Netz noch kalt ist.
    ///
    /// **Wenn der Server neue Kategorien/Typen hinzufügt:** der Fallback
    /// veraltet, aber alte iOS-Builds rendern weiter den letzten
    /// bekannten Stand statt eine leere Picker-Liste. Sobald der
    /// Online-Hit landet, übernimmt das frische Mapping.
    ///
    /// **Server-Coord-Note (R1):** wir bevorzugen den HTTP-Pfad. Dieser
    /// Fallback ist NUR der Offline-Schirm, nicht die Primärquelle.
    public static let bundledFallback: CategoryAssignmentMap = .init(
        version: 1,
        categories: [
            .init(id: "vitals", labelKey: "categories.vitals", order: 0),
            .init(id: "body", labelKey: "categories.body", order: 1),
            .init(id: "activity", labelKey: "categories.activity", order: 2),
            .init(id: "sleep", labelKey: "categories.sleep", order: 3),
            .init(id: "hearing", labelKey: "categories.hearing", order: 4),
            .init(id: "environment", labelKey: "categories.environment", order: 5),
            .init(id: "cardiovascular", labelKey: "categories.cardiovascular", order: 6),
            .init(id: "metabolic", labelKey: "categories.metabolic", order: 7),
            // v1.10.0 — server-derived wellness scores share their own list
            // grouping (`categories.ts` → "scores"). v0.14.1 W-B189 added the
            // first ServerMeasurementType members of this cluster (ANS_CHARGE /
            // CARDIO_LOAD), so the bundled fallback must carry the category too.
            .init(id: "scores", labelKey: "categories.scores", order: 8)
        ],
        assignments: [
            // vitals
            "BLOOD_PRESSURE_SYS": "vitals",
            "BLOOD_PRESSURE_DIA": "vitals",
            "PULSE": "vitals",
            "OXYGEN_SATURATION": "vitals",
            "BODY_TEMPERATURE": "vitals",
            // v0.11 marathon — respiratory rate is a vital sign (server
            // `categories.ts` maps RESPIRATORY_RATE → vitals).
            "RESPIRATORY_RATE": "vitals",
            // body
            "WEIGHT": "body",
            "BODY_FAT": "body",
            "FAT_FREE_MASS": "body",
            "FAT_MASS": "body",
            "LEAN_BODY_MASS": "body",
            "MUSCLE_MASS": "body",
            "TOTAL_BODY_WATER": "body",
            "BONE_MASS": "body",
            "VISCERAL_FAT": "body",
            // activity
            "ACTIVITY_STEPS": "activity",
            "ACTIVE_ENERGY_BURNED": "activity",
            "FLIGHTS_CLIMBED": "activity",
            "WALKING_RUNNING_DISTANCE": "activity",
            "VO2_MAX": "activity",
            "WALKING_STEADINESS": "activity",
            // v0.5.2 F2 — server enum NOT yet present, but ship the
            // categorisation so once the server adds them, the Picker
            // groups them correctly without an iOS client update.
            "WALKING_SPEED": "activity",
            "WALKING_STEP_LENGTH": "activity",
            // v0.11 marathon — the real server enum is WALKING_ASYMMETRY
            // (server `categories.ts` → activity), NOT the speculative
            // WALKING_ASYMMETRY_PERCENTAGE the v0.5.2 F2 stub guessed and
            // the server never adopted. WALKING_DOUBLE_SUPPORT joins it
            // (both gait metrics live in `activity` server-side).
            "WALKING_ASYMMETRY": "activity",
            "WALKING_DOUBLE_SUPPORT": "activity",
            "BODY_MASS_INDEX": "body",
            // sleep
            "SLEEP_DURATION": "sleep",
            // v0.13.1 IC — breathing disturbances is an overnight sleep metric.
            "BREATHING_DISTURBANCES": "sleep",
            // v0.14.6 — WHOOP-native sleep-disturbance count joins the sleep cluster.
            "SLEEP_DISTURBANCE_COUNT": "sleep",
            // v0.14.1 W-B189 — v1.17.1 source-fixed render-only signals (#23).
            // Server `categories.ts`: SLEEP_SCORE → sleep, ANS_CHARGE /
            // CARDIO_LOAD → scores, BODY_TEMPERATURE_DEVIATION → metabolic.
            "SLEEP_SCORE": "sleep",
            "ANS_CHARGE": "scores",
            "CARDIO_LOAD": "scores",
            "BODY_TEMPERATURE_DEVIATION": "metabolic",
            // hearing
            "AUDIO_EXPOSURE_ENV": "hearing",
            "AUDIO_EXPOSURE_HEADPHONE": "hearing",
            "AUDIO_EXPOSURE_EVENT": "hearing",
            // environment
            "TIME_IN_DAYLIGHT": "environment",
            // cardiovascular
            "RESTING_HEART_RATE": "cardiovascular",
            "HEART_RATE_VARIABILITY": "cardiovascular",
            "PULSE_WAVE_VELOCITY": "cardiovascular",
            "VASCULAR_AGE": "cardiovascular",
            "WALKING_HEART_RATE_AVERAGE": "cardiovascular",
            // v0.13.1 IC — cardio recovery is a heart-rate-derived cardio metric.
            "CARDIO_RECOVERY": "cardiovascular",
            // v0.14.6 — WHOOP-native avg/max HR are heart-rate-derived → cardiovascular.
            "AVERAGE_HEART_RATE": "cardiovascular",
            "MAX_HEART_RATE": "cardiovascular",
            // metabolic
            "BLOOD_GLUCOSE": "metabolic",
            "SKIN_TEMPERATURE": "metabolic",
            // v0.13.1 IC — overnight wrist temperature joins metabolic.
            "WRIST_TEMPERATURE": "metabolic",
            // v0.13.1 IC — v1.10.0 mobility/fitness signals join activity.
            "FALL_COUNT": "activity",
            "SIX_MINUTE_WALK_DISTANCE": "activity",
            "STAIR_ASCENT_SPEED": "activity",
            "STAIR_DESCENT_SPEED": "activity",
            // v0158 — v1.25 clinical measurement types. Mirror the server
            // `categories.ts`: PAIN_NRS → vitals, GRIP_STRENGTH → activity,
            // WAIST_CIRCUMFERENCE / WAIST_TO_HEIGHT → body. Keeps the offline
            // category fallback exhaustive over `ServerMeasurementType`.
            "PAIN_NRS": "vitals",
            "GRIP_STRENGTH": "activity",
            "WAIST_CIRCUMFERENCE": "body",
            "WAIST_TO_HEIGHT": "body",
            // Build 3 / 3.3 — die 21 Typen, die mit dem Decoder-Nachzug dazukamen.
            // Zuordnung 1:1 aus dem Server (`src/lib/measurements/categories.ts`)
            // uebernommen, nicht selbst kategorisiert: ohne Eintrag liefert
            // `categoryId(forRawType:)` nil und der Wert landet im Picker nirgends.
            "IRREGULAR_RHYTHM_NOTIFICATION": "cardiovascular",
            "HIGH_HEART_RATE_EVENT": "cardiovascular",
            "LOW_HEART_RATE_EVENT": "cardiovascular",
            "HRV_RMSSD": "cardiovascular",
            "WALKING_STEADINESS_EVENT": "activity",
            "ENERGY_EXPENDITURE_KJ": "activity",
            "BREATHING_DISTURBANCE_EVENT": "sleep",
            "SLEEP_PERFORMANCE": "sleep",
            "SLEEP_EFFICIENCY": "sleep",
            "SLEEP_CONSISTENCY": "sleep",
            "SLEEP_NEED": "sleep",
            "RECOVERY_SCORE": "scores",
            "STRESS_SCORE": "scores",
            "STRAIN_SCORE": "scores",
            "DAY_STRAIN": "scores",
            "WORKOUT_STRAIN": "scores",
            "RESILIENCE": "scores",
            "PHQ9_SCORE": "scores",
            "GAD7_SCORE": "scores",
            "WHO5_SCORE": "scores",
            "SCI_SCORE": "scores"
        ]
    )
}
