import Foundation

/// #160 / server #1313 (v1.46.6) — a lab value without a unit.
///
/// A ratio or an index (INR, cholesterol/HDL, albumin/globulin) carries the
/// UCUM unity `"1"` on the wire. No new field: `unit: "1"` on readings,
/// markers and document facts. It is a unit of its own (it matches only
/// `"1"`, no conversion ever involves it), but it is never PRINTED:
///
///   * after a number, nothing follows: "3,6", not "3,6 1" (also in range
///     labels, chart axes and VoiceOver);
///   * where the unit stands alone (a marker subtitle, a picker row, the
///     read-only "Unit" row of a linked marker) the app says "No unit".
///
/// An empty unit stays an empty unit. `"1"` is never inferred from an empty
/// field: only the explicit "No unit" switch next to a lab unit field sets it.
enum LabUnit {
    /// The UCUM unity, the wire value for "no unit".
    static let unity = "1"

    /// The first server that accepts and stores `"1"` (`labs.unit.none`).
    static let noUnitMinimumServerVersion = "1.46.6"

    /// `true` when `unit` is the UCUM unity (surrounding spaces ignored).
    static func isUnity(_ unit: String?) -> Bool {
        unit?.trimmingCharacters(in: .whitespaces) == unity
    }

    /// The unit to print after a number, or `nil` when nothing follows it
    /// (no unit at all, or the unity).
    static func suffix(_ unit: String?) -> String? {
        guard let trimmed = unit?.trimmingCharacters(in: .whitespaces), !trimmed.isEmpty else { return nil }
        return trimmed == unity ? nil : trimmed
    }

    /// `text` followed by its unit, or `text` alone when no unit prints.
    static func appending(_ unit: String?, to text: String) -> String {
        guard let suffix = suffix(unit) else { return text }
        return "\(text) \(suffix)"
    }

    /// The unit where it stands on its own: "No unit" for the unity, the
    /// unit itself otherwise, `nil` for an empty unit.
    static func standalone(_ unit: String?) -> String? {
        if isUnity(unit) { return String(localized: "labs.unit.none") }
        return suffix(unit)
    }

    /// What a lab unit field sends: the unity when "No unit" is on, else the
    /// typed unit trimmed, `nil` when the field is empty. An empty field never
    /// turns into `"1"`.
    static func wire(typed: String, noUnit: Bool) -> String? {
        if noUnit { return unity }
        let trimmed = typed.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Whether the "No unit" switch is offered: from server 1.46.6 on, and
    /// always when the value being edited already has no unit (so the form
    /// shows the stored state honestly). An unknown server version is no.
    static func offersNoUnit(current: String? = nil, defaults: UserDefaults = .standard) -> Bool {
        isUnity(current) || KnownServerVersion.isAtLeast(noUnitMinimumServerVersion, defaults: defaults)
    }
}

// MARK: - The unit of a marker

/// A marker minted from a text result (OCR, CSV, document inbox) stores an
/// empty unit: none chosen yet, its first number would set it. The editor
/// treats it like "No unit", and a save sends the unit only when it really
/// changes, so a rename never touches it.
extension LabUnit {
    /// The first server that lets a marker with an empty unit take a unit
    /// while only text results are linked. Older servers refuse any unit
    /// change on a marker with readings (`biomarkers.unit.locked`).
    static let emptyMarkerUnitMinimumServerVersion = "1.47.7"

    /// `true` for a marker without a unit: none chosen yet (empty) or the unity.
    static func isNoUnit(_ unit: String?) -> Bool {
        let trimmed = unit?.trimmingCharacters(in: .whitespaces) ?? ""
        return trimmed.isEmpty || trimmed == unity
    }

    /// Two marker units that mean the same: equal after trimming, or both
    /// "no unit" (the empty unit and the unity).
    static func sameMarkerUnit(_ lhs: String?, _ rhs: String?) -> Bool {
        if isNoUnit(lhs), isNoUnit(rhs) { return true }
        return lhs?.trimmingCharacters(in: .whitespaces) == rhs?.trimmingCharacters(in: .whitespaces)
    }

    /// The `unit` of a marker update: `nil` (key left out, unit untouched)
    /// unless the edited unit is a real change of the stored one.
    static func markerPatchUnit(stored: String, edited: String?) -> String? {
        guard let edited, !sameMarkerUnit(stored, edited) else { return nil }
        return edited
    }

    /// Whether the editor may change the unit of `stored`. Only a marker
    /// with an empty unit on a server before 1.47.7 is held: that server
    /// counts its text results and answers every change with 422. An unknown
    /// server version holds it too.
    static func markerUnitEditable(stored: String?, defaults: UserDefaults = .standard) -> Bool {
        guard let stored, stored.trimmingCharacters(in: .whitespaces).isEmpty else { return true }
        return KnownServerVersion.isAtLeast(emptyMarkerUnitMinimumServerVersion, defaults: defaults)
    }
}

extension LabUnit {
    /// Where a reading came from, in words. The server's
    /// `source` is a free string ("MANUAL" by default, "OCR" from a read
    /// report, "DOCUMENT" from a filed document, import paths their own);
    /// the detail page showed it raw. Anything unknown is "another source".
    static func sourceName(_ raw: String) -> String {
        switch raw.uppercased() {
        case "MANUAL": String(localized: "labs.source.manual")
        case "OCR": String(localized: "labs.source.report")
        case "DOCUMENT": String(localized: "labs.source.document")
        case "IMPORT", "FHIR": String(localized: "labs.source.import")
        default: String(localized: "labs.source.other")
        }
    }
}
