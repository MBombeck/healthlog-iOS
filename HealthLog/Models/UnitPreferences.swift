import Foundation

// MARK: - Display-unit prefs (v0.11 N1)

//
// Lives in `Models` (HealthLogCore) so the platform-free metric formatters
// in `MetricKindDescriptor` can convert at display time. The `@Observable`
// store properties + SwiftUI `EnvironmentValues` plumbing stay in
// `SettingsStore.swift` (app target).

/// Local-only display unit for body-mass values (weight, body-water, bone-mass).
///
/// **v0.11 N1 — wired end-to-end.** The server keeps storing canonical SI
/// units (kg). When the user picks `.lb` the value is converted **at display
/// time** by `UnitPreferences.convertWeight(_:)` and the unit label flips to
/// `"lb"`; nothing is re-persisted. UserDefaults usage stays inside the
/// "UI-prefs" allowlist per PROJECT_GUIDE.md (no Health-data, no tokens — purely
/// display).
public enum WeightUnit: String, CaseIterable, Identifiable, Sendable {
    case kg
    case lb

    public var id: String {
        rawValue
    }

    /// Full picker label, e.g. "Kilograms (kg)".
    public var label: String {
        switch self {
        case .kg: String(localized: "Kilograms (kg)", comment: "Weight unit — kilograms")
        case .lb: String(localized: "Pounds (lb)", comment: "Weight unit — pounds")
        }
    }

    /// Compact unit suffix shown next to a value, e.g. "kg".
    public var unitSuffix: String {
        switch self {
        case .kg: "kg"
        case .lb: "lb"
        }
    }
}

/// **Build 9 (Server-Prefs) / 9.1 — server-owned unit system.**
///
/// The server-resolved `"metric" | "imperial"` binary (`User.unitPreference`).
/// Follows the ``HLDateFormat`` mirror pattern: the server is authoritative;
/// `SettingsStore` mirrors the resolved value into ONE UserDefaults key
/// (``defaultsKey``) on hydration and this pure reader reads only that mirror
/// (``current(defaults:)``), defaulting to `.metric` until the first load.
///
/// **Decision A (plan §0.4 E-2):** the binary is the source of truth for the
/// weight-unit *default* — `weightUnit` follows it unless the user set an explicit
/// per-device override. BP/glucose stay local details (the web has no binary
/// coupling for them, plan §0.3.2).
public enum HLUnitPreference: String, CaseIterable, Sendable {
    case metric
    case imperial

    /// UserDefaults key the `SettingsStore` mirror writes and pure readers read.
    /// Namespaced like the other `hl.settings.*` UI-prefs.
    public static let defaultsKey = "hl.settings.unitPreference"

    /// The currently effective preference, read from the UserDefaults mirror.
    /// Defaults to `.metric` when unset (fresh install / pre-mirror) so the app
    /// stays on canonical SI until the server profile lands.
    public static func current(defaults: UserDefaults = .standard) -> HLUnitPreference {
        HLUnitPreference(rawValue: defaults.string(forKey: defaultsKey) ?? "") ?? .metric
    }

    /// The weight unit this system implies when the user has no explicit override
    /// (`metric → kg`, `imperial → lb`).
    public var defaultWeightUnit: WeightUnit {
        switch self {
        case .metric: .kg
        case .imperial: .lb
        }
    }

    /// Localised label for the Settings segmented picker.
    public var label: String {
        switch self {
        case .metric: String(localized: "settings.unitSystem.metric", comment: "Unit system — metric")
        case .imperial: String(localized: "settings.unitSystem.imperial", comment: "Unit system — imperial")
        }
    }
}

/// Local-only display unit for blood-pressure values. Canonical store = mmHg.
public enum BloodPressureUnit: String, CaseIterable, Identifiable, Sendable {
    case mmHg
    case kPa

    public var id: String {
        rawValue
    }

    public var label: String {
        switch self {
        case .mmHg: String(localized: "Millimeters of mercury (mmHg)", comment: "Blood-pressure unit — mmHg")
        case .kPa: String(localized: "Kilopascals (kPa)", comment: "Blood-pressure unit — kPa")
        }
    }

    public var unitSuffix: String {
        switch self {
        case .mmHg: "mmHg"
        case .kPa: "kPa"
        }
    }
}

/// Local-only display unit for blood-glucose values. Canonical store = mg/dL.
public enum GlucoseUnit: String, CaseIterable, Identifiable, Sendable {
    case mgdL
    case mmolL

    public var id: String {
        rawValue
    }

    public var label: String {
        switch self {
        case .mgdL: String(localized: "Milligrams per deciliter (mg/dL)", comment: "Glucose unit — mg/dL")
        case .mmolL: String(localized: "Millimoles per liter (mmol/L)", comment: "Glucose unit — mmol/L")
        }
    }

    public var unitSuffix: String {
        switch self {
        case .mgdL: "mg/dL"
        case .mmolL: "mmol/L"
        }
    }
}

/// Value-type snapshot of the three display-unit prefs, threaded into the
/// dashboard/metric display path so the conversion is a pure, testable
/// transform separate from the `@MainActor` store.
///
/// **v0.11 N1.** The server stores canonical SI units (kg / mmHg / mg/dL);
/// this type converts to the user's chosen unit **at display time only** and
/// supplies the matching unit suffix. `.standard` is the canonical-unit
/// identity (no conversion) used by call-sites that have no store handle.
public struct UnitPreferences: Sendable, Hashable {
    public var weight: WeightUnit
    public var bloodPressure: BloodPressureUnit
    public var glucose: GlucoseUnit

    public init(
        weight: WeightUnit = .kg,
        bloodPressure: BloodPressureUnit = .mmHg,
        glucose: GlucoseUnit = .mgdL
    ) {
        self.weight = weight
        self.bloodPressure = bloodPressure
        self.glucose = glucose
    }

    /// Canonical-unit identity — no conversion, SI suffixes.
    public static let standard = UnitPreferences()

    /// kg → lb factor (1 kg = 2.2046226218 lb).
    static let kgToLb = 2.2046226218
    /// mmHg → kPa factor (1 mmHg = 0.133322387415 kPa).
    static let mmHgToKPa = 0.133322387415
    /// mg/dL → mmol/L factor for glucose (divide by 18.0182).
    static let mgdLToMmolL = 1.0 / 18.0182

    /// Converts a canonical kg value into the chosen weight unit.
    public func convertWeight(_ kgValue: Double) -> Double {
        switch weight {
        case .kg: kgValue
        case .lb: kgValue * Self.kgToLb
        }
    }

    /// Converts a canonical mmHg value into the chosen BP unit.
    public func convertBloodPressure(_ mmHgValue: Double) -> Double {
        switch bloodPressure {
        case .mmHg: mmHgValue
        case .kPa: mmHgValue * Self.mmHgToKPa
        }
    }

    /// Converts a canonical mg/dL value into the chosen glucose unit.
    public func convertGlucose(_ mgdLValue: Double) -> Double {
        switch glucose {
        case .mgdL: mgdLValue
        case .mmolL: mgdLValue * Self.mgdLToMmolL
        }
    }
}
