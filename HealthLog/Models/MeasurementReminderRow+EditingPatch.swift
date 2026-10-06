import Foundation

// **Build 6.4 / v1.39.2 — the edit-sheet's PATCH body, as a pure function.**
//
// Split out of `MeasurementReminderRow.swift` (file-length discipline) when it
// changed from "every field, every save" to "only what the person changed".

extension MeasurementReminderRow {
    /// **Builds the PATCH body for editing `row` with the form's current values
    /// — carrying ONLY the fields that differ from the row.**
    ///
    /// **Why only the changed fields (server v1.39.2).** Before v1.39.2 the
    /// server recomputed `nextDueAt` from *now* on every PATCH. An open,
    /// overdue yearly check-up whose edit sheet was saved — even to fix a typo
    /// in its label — rolled into next year. v1.39.2 compares the cadence by
    /// value and keeps the due date unless `intervalDays`, `rrule` or
    /// `anchorDate` (by calendar day in the profile zone) change, or a disabled
    /// reminder is switched back on; a `notifyHour`-only edit moves the hour on
    /// the same day. An older server still recomputes on any PATCH, so the app
    /// sends as little as it can: an untouched field is omitted, and a save with
    /// nothing changed sends nothing (``MeasurementReminderUpdate/isEmpty``).
    ///
    /// **Cadence exclusivity + the #62 fix.** `intervalDays` and `rrule` are
    /// EXCLUSIVE server-side: setting one while omitting the other clears the
    /// other, and the recompute keys off what is actually persisted. So a
    /// changed cadence is sent as its own family only:
    ///   - **Interval mode** → `intervalDays = .set(n)`, `rrule` omitted. The
    ///     server clears `rrule` via the exclusivity rule.
    ///   - **RRULE mode** → `rrule = .set(rule)`, `intervalDays` omitted. The
    ///     server clears `intervalDays`.
    /// An unchanged cadence omits both. A rule counts as unchanged when it only
    /// differs in case or spaces (the preset mapping normalises those), so
    /// opening and saving never rewrites a stored `freq=yearly` as
    /// `FREQ=YEARLY` — the server would read that as a changed rule.
    ///
    /// **Tri-state clearable fields.** `measurementType`, `anchorDate` and
    /// `location` carry a ``RecordPatchField``: a changed value → `.set`, an
    /// emptied field that HAD a value → `.clear` (explicit JSON `null`), an
    /// untouched one → `.unchanged` (omitted). The anchor counts as untouched
    /// when it names the same calendar day in the profile zone, which is exactly
    /// how v1.39.2 compares it.
    static func editingPatch(
        for row: MeasurementReminderRow,
        label: String,
        measurementType: String?,
        cadence: ReminderCadence,
        anchorDate: Date?,
        notifyHour: Int,
        location: String?,
        enabled: Bool,
        timeZone: TimeZone = ProfileDay.timeZone
    ) -> MeasurementReminderUpdate {
        let intervalField: RecordPatchField<Int>
        let rruleField: RecordPatchField<String>
        switch cadence {
        case let .interval(days):
            let unchanged = !row.isRRuleScheduled && row.intervalDays == days
            intervalField = unchanged ? .unchanged : .set(days)
            rruleField = .unchanged
        case let .rrule(rule):
            let unchanged = row.isRRuleScheduled && Self.normalisedRule(row.rrule) == Self.normalisedRule(rule)
            rruleField = unchanged ? .unchanged : .set(rule)
            intervalField = .unchanged
        }

        let trimmedType = measurementType.flatMap { $0.isEmpty ? nil : $0 }
        let trimmedLocation = location?.trimmingCharacters(in: .whitespacesAndNewlines)
        let newLocation = (trimmedLocation?.isEmpty == false) ? trimmedLocation : nil

        return MeasurementReminderUpdate(
            label: label == row.label ? nil : label,
            measurementType: trimmedType == row.measurementType
                ? .unchanged
                : Self.clearableField(new: trimmedType, had: row.measurementType != nil),
            intervalDays: intervalField,
            rrule: rruleField,
            anchorDate: Self.anchorField(new: anchorDate, stored: row.anchorDate, timeZone: timeZone),
            notifyHour: notifyHour == row.notifyHour ? nil : notifyHour,
            location: newLocation == row.location
                ? .unchanged
                : Self.clearableField(new: newLocation, had: row.location != nil),
            enabled: enabled == row.enabled ? nil : enabled
        )
    }

    /// Tri-state a clearable string field: a non-empty value → `.set`; an
    /// empty/`nil` value that HAD a stored value → `.clear`; otherwise omit.
    private static func clearableField(new value: String?, had: Bool) -> RecordPatchField<String> {
        if let value, !value.isEmpty { return .set(value) }
        return had ? .clear : .unchanged
    }

    /// The anchor: omitted while it names the stored calendar day, `null` when
    /// the person removed it, the new instant otherwise.
    private static func anchorField(new value: Date?, stored: Date?, timeZone: TimeZone) -> RecordPatchField<Date> {
        switch (value, stored) {
        case (nil, nil):
            return .unchanged
        case (nil, .some):
            return .clear
        case let (.some(new), nil):
            return .set(new)
        case let (.some(new), .some(old)):
            let sameDay = ProfileDay.key(for: new, timeZone: timeZone) == ProfileDay.key(for: old, timeZone: timeZone)
            return sameDay ? .unchanged : .set(new)
        }
    }

    /// A rule compared the way ``RRulePreset/init(wire:)`` maps it: case and
    /// spaces do not make a different schedule.
    private static func normalisedRule(_ rule: String?) -> String {
        (rule ?? "").uppercased().replacingOccurrences(of: " ", with: "")
    }
}
