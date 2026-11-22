// `GlucoseContext` moves out of `MeasurementDTO.swift`. **Pure
// move** (same module, same access levels, same behaviour); only the file
// boundary changes. The wire enum that carries an unknown server measurement
// type has to be declared in `MeasurementDTO.swift` itself, and that file sits
// against a baselined length ceiling — the glucose discriminator is the piece
// with the cleanest boundary, so it pays for the lines.
import Foundation

/// Discriminator-Context für Blutzucker-Messungen. Source of Truth: the
/// server's `GlucoseContext` Postgres enum and `glucoseContextEnum`
/// (`src/lib/validations/measurement.ts`): FASTING / POSTPRANDIAL / RANDOM /
/// BEDTIME, on POST and, from server 1.48.0, on `PUT /api/measurements/{id}`.
///
/// Until 1.7 this enum carried BEFORE_MEAL and AFTER_MEAL, which the server
/// never accepted (422 on create) and never sent (a POSTPRANDIAL or RANDOM
/// row lost its context on read). The cases now carry the server's literals.
/// A value persisted by an older build (an outbox payload) still decodes:
/// AFTER_MEAL is POSTPRANDIAL, BEFORE_MEAL lands on RANDOM, the server's
/// bucket for "not fasting, not after a meal".
///
/// **Display-Strings (DE primary):** "Nüchtern" / "Nach Mahlzeit" /
/// "Beliebig" / "Schlafenszeit". Display wird über `LocalizedStringResource`
/// in `displayResource` aufgelöst, nicht über `displayName` (hardcoded
/// PROJECT_GUIDE.md-Anti-Pattern).
///
/// **HK-Mapping:** Apple's `HKMetadataKeyBloodGlucoseMealTime` kennt nur
/// `.preprandial` / `.postprandial`: fasting → `.preprandial`, afterMeal →
/// `.postprandial`, random und bedtime haben kein HK-Pendant.
///
/// **Bewusst GESCHLOSSEN, Toleranz sitzt am Lesepfad.** Das Enum hat
/// keinen Unbekannt-Fall, weil `allCases` die Kontext-Picker in
/// `MeasureSheetView` / `EditMeasurementSheet` speist — ein Sammelfall wäre
/// dort eine anwählbare Option. Ein künftiges Server-Literal fängt statt
/// dessen `MeasurementWireDTO.init(from:)` ab (String-Decode → `nil`), sodass
/// die Messzeile überlebt statt verworfen zu werden.
public enum GlucoseContext: String, Codable, Sendable, CaseIterable, Identifiable {
    case fasting = "FASTING"
    case afterMeal = "POSTPRANDIAL"
    case random = "RANDOM"
    case bedtime = "BEDTIME"

    public var id: String {
        rawValue
    }

    /// The literals of builds before 1.7, read from what they persisted.
    static let legacyLiterals: [String: GlucoseContext] = [
        "AFTER_MEAL": .afterMeal,
        "BEFORE_MEAL": .random
    ]

    public init(from decoder: Decoder) throws {
        let literal = try decoder.singleValueContainer().decode(String.self)
        guard let context = GlucoseContext(rawValue: literal) ?? Self.legacyLiterals[literal] else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unknown glucose context \(literal)")
            )
        }
        self = context
    }

    /// Localized label for picker rows + chart annotations. Resolved against
    /// `Localizable.xcstrings`; DE primary, EN secondary.
    public var displayResource: LocalizedStringResource {
        switch self {
        case .fasting: LocalizedStringResource("Fasting", comment: "Glucose context — fasting")
        case .afterMeal: LocalizedStringResource("After meal", comment: "Glucose context — after meal")
        case .random: LocalizedStringResource("glucose.context.random", comment: "Glucose context — random, any other time")
        case .bedtime: LocalizedStringResource("Bedtime", comment: "Glucose context — bedtime")
        }
    }
}
