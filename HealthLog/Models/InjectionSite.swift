import Foundation

/// Canonical injection-site list — abdomen left/right quadrants, thigh
/// left/right, upper-arm left/right. Eight rotation slots match the standard
/// rotation pattern the EMA EPAR §4.2 references.
///
/// **v0.11 — moved out of `Screens/GLP1/GLP1LocalEntities.swift` into the
/// plattform-free Models layer** so the medications repository + intake wire
/// bodies (which live in the Core / widget-extension target closure) can
/// thread an `injectionSite` through the v1.8.5 take-write paths. The
/// SwiftData GLP-1 logbook entities keep referencing it unchanged.
///
/// The `rawValue` is the **legacy local** lowercase string (kept for the
/// on-device SwiftData rows). The v1.8.5 **server** enum is a separate
/// taxonomy bridged via ``serverRawValue`` / ``fromServerRawValue(_:)``.
public enum InjectionSite: String, Codable, CaseIterable, Sendable, Hashable {
    case abdomenLeftUpper = "abdomen_left_upper"
    case abdomenRightUpper = "abdomen_right_upper"
    case abdomenLeftLower = "abdomen_left_lower"
    case abdomenRightLower = "abdomen_right_lower"
    case thighLeft = "thigh_left"
    case thighRight = "thigh_right"
    case armLeft = "arm_left"
    case armRight = "arm_right"

    /// Localized human-readable label. Lives on the enum so picker UIs
    /// can render without a separate switch.
    public var localizedLabel: String {
        switch self {
        case .abdomenLeftUpper: String(localized: "med.injection.site.abdomen_left_upper")
        case .abdomenRightUpper: String(localized: "med.injection.site.abdomen_right_upper")
        case .abdomenLeftLower: String(localized: "med.injection.site.abdomen_left_lower")
        case .abdomenRightLower: String(localized: "med.injection.site.abdomen_right_lower")
        case .thighLeft: String(localized: "med.injection.site.thigh_left")
        case .thighRight: String(localized: "med.injection.site.thigh_right")
        case .armLeft: String(localized: "med.injection.site.arm_left")
        case .armRight: String(localized: "med.injection.site.arm_right")
        }
    }

    /// Best-effort parser for the server's raw injection-site strings
    /// (used by `PaginatedIntakeEvent.injectionSite`). Accepts BOTH the
    /// legacy local lowercase raw values (`abdomen_left_upper`) AND the
    /// v1.8.5 server enum (`ABDOMEN_UPPER_LEFT`, …). Returns `nil` for
    /// unknown values — the caller falls back to a generic "Unbekannte
    /// Stelle" label and skips the rotation hint.
    public static func parse(_ raw: String?) -> InjectionSite? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespaces),
              !trimmed.isEmpty else { return nil }
        // Server enum first (v1.8.5 wire), then legacy local lowercase.
        if let server = fromServerRawValue(trimmed.uppercased()) {
            return server
        }
        return InjectionSite(rawValue: trimmed.lowercased())
    }

    // MARK: - v1.8.5 server enum bridge (server-to-ios injection-site)

    /// The server's v1.8.5 `InjectionSite` enum string for this case. The
    /// server's abdomen taxonomy is `LEFT/RIGHT` (lower) + `UPPER_LEFT/
    /// UPPER_RIGHT`, while the local enum names the lower quadrants
    /// explicitly — so `abdomenLeftLower` ↔ `ABDOMEN_LEFT` and
    /// `abdomenLeftUpper` ↔ `ABDOMEN_UPPER_LEFT`. Upper-arm maps to the
    /// server's `UPPER_ARM_*`.
    public var serverRawValue: String {
        switch self {
        case .abdomenLeftLower: "ABDOMEN_LEFT"
        case .abdomenRightLower: "ABDOMEN_RIGHT"
        case .abdomenLeftUpper: "ABDOMEN_UPPER_LEFT"
        case .abdomenRightUpper: "ABDOMEN_UPPER_RIGHT"
        case .thighLeft: "THIGH_LEFT"
        case .thighRight: "THIGH_RIGHT"
        case .armLeft: "UPPER_ARM_LEFT"
        case .armRight: "UPPER_ARM_RIGHT"
        }
    }

    /// Inverse of ``serverRawValue`` — maps a v1.8.5 server enum string
    /// back to the local case. Returns `nil` for unknown values.
    public static func fromServerRawValue(_ raw: String) -> InjectionSite? {
        switch raw {
        case "ABDOMEN_LEFT": .abdomenLeftLower
        case "ABDOMEN_RIGHT": .abdomenRightLower
        case "ABDOMEN_UPPER_LEFT": .abdomenLeftUpper
        case "ABDOMEN_UPPER_RIGHT": .abdomenRightUpper
        case "THIGH_LEFT": .thighLeft
        case "THIGH_RIGHT": .thighRight
        case "UPPER_ARM_LEFT": .armLeft
        case "UPPER_ARM_RIGHT": .armRight
        default: nil
        }
    }
}

/// Pure effective-allowed-set computation for the v1.8.5 injection-site
/// gating contract. Mirrors the server rule:
///
/// effective = (`allowed` or all eight when empty) − `globalExcluded`
///
/// **Deny always wins** — a globally-excluded site is never valid even if
/// a medication lists it as preferred. Kept order-stable (`allCases`
/// order) so the picker renders deterministically.
public enum InjectionSiteEffectiveSet {
    public static func effective(
        allowed: [InjectionSite],
        globalExcluded: [InjectionSite]
    ) -> [InjectionSite] {
        let base = allowed.isEmpty ? InjectionSite.allCases : allowed
        let denied = Set(globalExcluded)
        let allowedSet = Set(base)
        return InjectionSite.allCases.filter { allowedSet.contains($0) && !denied.contains($0) }
    }
}
