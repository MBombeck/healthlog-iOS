// Audit B-4 — `GlucoseContext` moves out of `MeasurementDTO.swift`. **Pure
// move** (same module, same access levels, same behaviour); only the file
// boundary changes. The wire enum that carries an unknown server measurement
// type has to be declared in `MeasurementDTO.swift` itself, and that file sits
// against a baselined length ceiling — the glucose discriminator is the piece
// with the cleanest boundary, so it pays for the lines.
import Foundation

/// Discriminator-Context für Blutzucker-Messungen. Source of Truth: Server-
/// `MeasurementContext`-Enum (`src/lib/validations/measurement.ts`). Server-
/// Wire akzeptiert die vier camelCase-Mappings (FASTING / BEFORE_MEAL /
/// AFTER_MEAL / BEDTIME) auf POST + PATCH und persistiert sie pro Glucose-
/// Row, sodass Series-Charts + Alerts pro Context gruppieren können.
///
/// **Display-Strings (DE primary):** "Nüchtern" / "Vor Mahlzeit" /
/// "Nach Mahlzeit" / "Schlafenszeit". Englische Lokalisierung lebt in
/// `Localizable.xcstrings` — Display wird über `LocalizedStringResource`
/// in `displayResource` aufgelöst, nicht über `displayName` (hardcoded
/// PROJECT_GUIDE.md-Anti-Pattern).
///
/// **HK-Mapping:** Apple's `HKMetadataKeyBloodGlucoseMealTime` nimmt eines
/// von `HKBloodGlucoseMealTime.preprandial` / `.postprandial`. Map:
/// fasting + beforeMeal → `.preprandial`, afterMeal → `.postprandial`,
/// bedtime → kein HK-Pendant (kein metadataValue gesetzt). Siehe
/// `HealthKitService.writeMeasurement` für den Schreibpfad.
///
/// **CU-18 — bewusst GESCHLOSSEN, Toleranz sitzt am Lesepfad.** Das Enum hat
/// keinen Unbekannt-Fall, weil `allCases` die Kontext-Picker in
/// `MeasureSheetView` / `EditMeasurementSheet` speist — ein Sammelfall wäre
/// dort eine anwählbare Option. Ein künftiges Server-Literal fängt statt
/// dessen `MeasurementWireDTO.init(from:)` ab (String-Decode → `nil`), sodass
/// die Messzeile überlebt statt verworfen zu werden.
public enum GlucoseContext: String, Codable, Sendable, CaseIterable, Identifiable {
    case fasting = "FASTING"
    case beforeMeal = "BEFORE_MEAL"
    case afterMeal = "AFTER_MEAL"
    case bedtime = "BEDTIME"

    public var id: String {
        rawValue
    }

    /// Localized label for picker rows + chart annotations. Resolved against
    /// `Localizable.xcstrings`; DE primary, EN secondary.
    public var displayResource: LocalizedStringResource {
        switch self {
        case .fasting: LocalizedStringResource("Fasting", comment: "Glucose context — fasting")
        case .beforeMeal: LocalizedStringResource("Before meal", comment: "Glucose context — before meal")
        case .afterMeal: LocalizedStringResource("After meal", comment: "Glucose context — after meal")
        case .bedtime: LocalizedStringResource("Bedtime", comment: "Glucose context — bedtime")
        }
    }
}
