import Foundation

/// Per-Kategorie-Gruppierung der HK-Read-Permissions in der Onboarding-Card.
/// Ein Eintrag pro UI-Row (kein 1:1 zu HKObjectType — eine Row bündelt
/// `bodyMass + bodyFatPercentage` etc., damit der User keine zwölf Zeilen
/// "Vital-Signs" durchscrollen muss).
///
/// Das Ist-Soll bleibt: jeder Read-Type aus `HealthKitService.defaultReadTypes`
/// ist hier in genau EINER Gruppe genannt — A1-Audit H3.
///
/// **CAT-1 (`v1.4.30.1`):** jede Row trägt einen `categoryId`-Stempel, der
/// auf einen `CategoryAssignmentMap`-Bucket (`vitals`, `body`, `activity`,
/// `sleep`, `hearing`, `environment`, `cardiovascular`, `metabolic`)
/// zeigt. Das erlaubt der Picker-UI, sich von der Server-getriebenen
/// `MeasurementCategoriesRepository` umsortieren zu lassen, sobald der
/// Server eine Kategorie umsortiert oder einen neuen Bucket einführt.
public struct HealthKitPermissionGroup: Identifiable, Sendable, Equatable {
    public let id: String
    public let symbolName: String
    public let title: String
    public let directionLabel: String
    /// `CategoryAssignmentMap.Category.id` des Buckets, in dem diese Row
    /// in der Picker-Liste landet. Wenn der Server eine `assignments`-
    /// Map liefert, sortiert das Picker-UI alle Rows mit demselben
    /// `categoryId` zusammen und ordnet die Buckets nach dem `order`-
    /// Feld der Server-Antwort.
    public let categoryId: String

    public init(
        id: String,
        symbolName: String,
        title: String,
        directionLabel: String,
        categoryId: String
    ) {
        self.id = id
        self.symbolName = symbolName
        self.title = title
        self.directionLabel = directionLabel
        self.categoryId = categoryId
    }

    /// Reihenfolge bewusst: Vitals zuerst (häufigster Apple-Watch-Use-Case),
    /// dann Aktivität, dann Schlaf + Audio + Daylight. Die Rows sind hier
    /// in der Reihenfolge gelistet, die der hartcodierte Fallback liefern
    /// würde — sobald die Server-Map vorliegt, übernimmt
    /// ``ordered(by:)`` die kanonische Reihenfolge.
    /// audit 02 · H-4 — row titles + direction labels are now localization keys
    /// (`String(localized:)`), not hardcoded DE/EN data strings. Previously the
    /// literals (e.g. "Gewicht & Körperfett" next to "Blood pressure") were
    /// passed through the `title:`/`directionLabel:` params and never localized,
    /// so the permission sheet mixed German and English mid-flow. The catalog
    /// carries both `de` (primary) and `en` for every key.
    public static let onboardingDefaults: [HealthKitPermissionGroup] = [
        .init(
            id: "vitals.body",
            symbolName: "scalemass",
            title: String(localized: "onboarding.healthkit.row.body"),
            directionLabel: String(localized: "onboarding.healthkit.direction.readWrite"),
            categoryId: "body"
        ),
        .init(
            id: "vitals.bodyTemperature",
            symbolName: "thermometer",
            title: String(localized: "onboarding.healthkit.row.bodyTemperature"),
            directionLabel: String(localized: "onboarding.healthkit.direction.read"),
            categoryId: "vitals"
        ),
        .init(
            id: "vitals.bloodPressure",
            symbolName: "waveform.path.ecg",
            title: String(localized: "onboarding.healthkit.row.bloodPressure"),
            directionLabel: String(localized: "onboarding.healthkit.direction.readWrite"),
            categoryId: "vitals"
        ),
        .init(
            id: "vitals.bloodGlucose",
            symbolName: "drop.fill",
            title: String(localized: "onboarding.healthkit.row.bloodGlucose"),
            directionLabel: String(localized: "onboarding.healthkit.direction.readWrite"),
            categoryId: "metabolic"
        ),
        .init(
            id: "vitals.spo2",
            symbolName: "lungs.fill",
            title: String(localized: "onboarding.healthkit.row.oxygenSaturation"),
            directionLabel: String(localized: "onboarding.healthkit.direction.read"),
            categoryId: "vitals"
        ),
        .init(
            id: "cardio.pulse",
            symbolName: "heart.fill",
            title: String(localized: "onboarding.healthkit.row.pulse"),
            directionLabel: String(localized: "onboarding.healthkit.direction.read"),
            categoryId: "cardiovascular"
        ),
        .init(
            id: "activity.steps",
            symbolName: "figure.walk",
            title: String(localized: "onboarding.healthkit.row.activity"),
            directionLabel: String(localized: "onboarding.healthkit.direction.read"),
            categoryId: "activity"
        ),
        .init(
            id: "sleep",
            symbolName: "bed.double.fill",
            title: String(localized: "onboarding.healthkit.row.sleep"),
            directionLabel: String(localized: "onboarding.healthkit.direction.read"),
            categoryId: "sleep"
        ),
        .init(
            id: "audio",
            symbolName: "speaker.wave.3.fill",
            title: String(localized: "onboarding.healthkit.row.audio"),
            directionLabel: String(localized: "onboarding.healthkit.direction.read"),
            categoryId: "hearing"
        ),
        .init(
            id: "daylight",
            symbolName: "sun.max.fill",
            title: String(localized: "onboarding.healthkit.row.daylight"),
            directionLabel: String(localized: "onboarding.healthkit.direction.read"),
            categoryId: "environment"
        )
    ]

    /// Server-getriebenes Re-Sort: behält die Rows aus ``onboardingDefaults``
    /// (oder einer expliziten Liste), sortiert sie aber nach der vom Server
    /// gelieferten Bucket-Order. Innerhalb eines Buckets gewinnt die
    /// Default-Reihenfolge der Eingabe — die ist UX-optimiert (Gewicht
    /// vor Temperatur etc.) und sollte vom Server-Bucket nicht überschrieben
    /// werden.
    ///
    /// Wenn ein Bucket im `map.orderedCategories` nicht erscheint (z. B.
    /// alter Server-Build, der `cardiovascular` noch nicht kennt), sortieren
    /// wir die unbekannten Rows hintendran — defensiv statt droppen.
    public static func ordered(
        by map: CategoryAssignmentMap,
        groups: [HealthKitPermissionGroup] = HealthKitPermissionGroup.onboardingDefaults
    ) -> [HealthKitPermissionGroup] {
        let categoryOrder: [String: Int] = Dictionary(
            uniqueKeysWithValues: map.orderedCategories.enumerated().map { ($1.id, $0) }
        )
        let unknownOrder = map.orderedCategories.count // hinten dran für unbekannte Buckets
        return groups
            .enumerated()
            .sorted { lhs, rhs in
                let lOrder = categoryOrder[lhs.element.categoryId] ?? unknownOrder
                let rOrder = categoryOrder[rhs.element.categoryId] ?? unknownOrder
                if lOrder != rOrder { return lOrder < rOrder }
                // Stable innerhalb desselben Buckets — Index aus der
                // Eingabeliste hält die UX-optimierte Default-Reihenfolge.
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }
}
