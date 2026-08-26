import SwiftUI

// Presentation helpers for the v1.25 structured-records surfaces (Allergies +
// Family history): localized labels for the picker enums + a clamped onset date
// range. Kept separate so the screens stay thin and the labels are testable.

extension AllergyCategory {
    /// Localized display label (`allergy.category.*`).
    var localizedLabel: String {
        switch self {
        case .food: String(localized: "allergy.category.food")
        case .medication: String(localized: "allergy.category.medication")
        case .environment: String(localized: "allergy.category.environment")
        case .biologic: String(localized: "allergy.category.biologic")
        case .other: String(localized: "allergy.category.other")
        }
    }
}

extension AllergyType {
    /// Localized display label (`allergy.type.*`).
    var localizedLabel: String {
        switch self {
        case .allergy: String(localized: "allergy.type.allergy")
        case .intolerance: String(localized: "allergy.type.intolerance")
        }
    }
}

extension AllergySeverity {
    /// Localized display label (`allergy.severity.*`).
    var localizedLabel: String {
        switch self {
        case .mild: String(localized: "allergy.severity.mild")
        case .moderate: String(localized: "allergy.severity.moderate")
        case .severe: String(localized: "allergy.severity.severe")
        }
    }
}

extension AllergyStatus {
    /// Localized display label (`allergy.status.*`).
    var localizedLabel: String {
        switch self {
        case .active: String(localized: "allergy.status.active")
        case .inactive: String(localized: "allergy.status.inactive")
        case .resolved: String(localized: "allergy.status.resolved")
        }
    }
}

extension FamilyRelationship {
    /// Localized display label (`family.relationship.*`).
    var localizedLabel: String {
        switch self {
        case .mother: String(localized: "family.relationship.mother")
        case .father: String(localized: "family.relationship.father")
        case .sister: String(localized: "family.relationship.sister")
        case .brother: String(localized: "family.relationship.brother")
        case .daughter: String(localized: "family.relationship.daughter")
        case .son: String(localized: "family.relationship.son")
        case .grandmotherMaternal: String(localized: "family.relationship.grandmotherMaternal")
        case .grandfatherMaternal: String(localized: "family.relationship.grandfatherMaternal")
        case .grandmotherPaternal: String(localized: "family.relationship.grandmotherPaternal")
        case .grandfatherPaternal: String(localized: "family.relationship.grandfatherPaternal")
        case .aunt: String(localized: "family.relationship.aunt")
        case .uncle: String(localized: "family.relationship.uncle")
        case .cousin: String(localized: "family.relationship.cousin")
        case .halfSibling: String(localized: "family.relationship.halfSibling")
        case .other: String(localized: "family.relationship.other")
        }
    }
}

/// Shared date helpers for the records editor onset pickers.
enum RecordsDateFormat {
    /// The valid onset range the server accepts: 1900-01-01 … now. Clamping the
    /// `DatePicker` to this range avoids a round-trip `422 allergy.invalid` (the
    /// server rejects future / pre-1900 instants — INV-B caveat).
    static let onsetRange: ClosedRange<Date> = {
        var comps = DateComponents()
        comps.year = 1900
        comps.month = 1
        comps.day = 1
        comps.timeZone = TimeZone(identifier: "UTC")
        let lower = Calendar(identifier: .gregorian).date(from: comps) ?? Date(timeIntervalSince1970: 0)
        return lower ... Date.now
    }()

    /// M1 — encode a user-picked onset DAY as a stable, day-anchored ISO-8601
    /// instant: **noon UTC** of the picked calendar day (read in the user's local
    /// calendar). The onset is a DATE, not a moment; encoding local-midnight via a
    /// UTC formatter (the old path) rolled the stored day BACK one calendar day for
    /// users west of UTC (and forward for users far east), silently smearing a
    /// clinical onset date. Anchoring at noon UTC keeps the date identical in every
    /// timezone. The server clamps 1900…now and only the date portion is read.
    static func onsetInstant(forDay day: Date, calendar: Calendar = .current) -> String {
        let comps = calendar.dateComponents([.year, .month, .day], from: day)
        var utc = DateComponents()
        utc.year = comps.year
        utc.month = comps.month
        utc.day = comps.day
        utc.hour = 12
        var gregorianUTC = Calendar(identifier: .gregorian)
        gregorianUTC.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let anchored = gregorianUTC.date(from: utc) ?? day
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return formatter.string(from: anchored)
    }

    /// Whether a stored onset ISO instant and a locally-picked day represent the
    /// SAME calendar day — so the editor can skip re-emitting an untouched onset.
    /// The stored instant is read in UTC (matching how ``onsetInstant`` anchors it),
    /// the picked day in the local calendar.
    static func isSameOnsetDay(storedInstant raw: String, asPickedDay day: Date) -> Bool {
        guard let stored = ISO8601DateFormatter.fractional.date(from: raw)
            ?? ISO8601DateFormatter.plain.date(from: raw) else { return false }
        var utcCal = Calendar(identifier: .gregorian)
        utcCal.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let storedDay = utcCal.dateComponents([.year, .month, .day], from: stored)
        let pickedDay = Calendar.current.dateComponents([.year, .month, .day], from: day)
        return storedDay.year == pickedDay.year
            && storedDay.month == pickedDay.month
            && storedDay.day == pickedDay.day
    }

    /// Medium date (e.g. "Jun 10, 2026") from an ISO-8601 instant. Falls back to
    /// the raw string if unparseable. Routes through ``HLDateFormat`` so the field
    /// order honours the user's date-format preference.
    static func mediumDate(_ raw: String) -> String {
        if let date = ISO8601DateFormatter.fractional.date(from: raw) {
            return HLDateFormat.date(date, style: .abbreviated)
        }
        if let date = ISO8601DateFormatter.plain.date(from: raw) {
            return HLDateFormat.date(date, style: .abbreviated)
        }
        return raw
    }
}
