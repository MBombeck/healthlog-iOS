import Foundation

/// **1.5 VISIT** — the sharing surface opened from "Nächster Termin" with the
/// visit's window preset (`preparation.from` to `.to`).
///
/// The window is a preset, not a second period: it rides on every output that
/// can carry a range (the PDF on the server and on the device, the package,
/// the link's `rangeStart`) and leaves the saved profile's `rangeDays` alone.
/// FHIR cannot carry one (`$everything` is scoped by the saved profile), so
/// choosing FHIR drops the preset rather than producing a file for a different
/// stretch than the one on screen. Choosing a look-back does the same.
public extension UnifiedSharingStore {
    /// Forms whose request carries the window.
    static func formTakesWindow(_ form: OutputForm) -> Bool {
        form != .fhir
    }

    /// Preset the window, as "visit.next.report" does. Ignored
    /// for a form that cannot carry it.
    func presetWindow(_ window: ReportWindow?) {
        self.window = Self.formTakesWindow(outputForm) ? window : nil
    }

    /// The period card's choice: a look-back of `days`, which ends the preset.
    func chooseLookBack(_ days: Int) {
        window = nil
        periodDays = days
    }

    /// The preset as instants in this store's calendar, stopped at now.
    var windowInterval: DateInterval? {
        window?.interval(calendar: calendar, now: now())
    }

    /// `range` for the export route: the preset window when there is one,
    /// else the look-back.
    var exportRange: HealthRecordExportRequest.Range {
        window?.exportRange(calendar: calendar, now: now())
            ?? HealthRecordExportRequest.Range(days: periodDays)
    }
}
