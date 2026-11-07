import Foundation

public extension MedicationWireDTO {
    /// Build the domain-shape consumed by the UI. **v0.10 R1:** decodes every
    /// server schedule row non-lossily into a ``ScheduleEntry`` (cadence +
    /// times-of-day + grace), applying the server dispatch precedence
    /// (one-shot → rolling → rrule → legacy), and threads the medication-level
    /// course window (`startsOn`/`endsOn`/`oneShot`/`deliveryForm`). The legacy
    /// flattened `times`/`weekdays`/`intervalWeeks` surface is derived from the
    /// entries for the pre-v0.10 render paths.
    func toDomain() -> Medication {
        let isOneShot = oneShot ?? false
        // v1.39.1 (#1033) — a medication kept as a record plans nothing. The
        // server already serves it with `schedules: []`; the domain schedule
        // is emptied here as well, so no reminder, alarm, Live Activity or
        // synthesised dose can ever be derived from a row that says otherwise.
        let tracked = trackIntake != false
        let entries = tracked ? (schedules ?? []).map { ScheduleEntry.fromDTO($0, oneShot: isOneShot) } : []
        let schedule: MedicationSchedule = entries.isEmpty
            ? MedicationSchedule(times: [])
            : MedicationSchedule(entries: entries)
        let recordedEntries = (recordedSchedules ?? []).map { ScheduleEntry.fromDTO($0, oneShot: isOneShot) }
        let recordedSchedule: MedicationSchedule? = tracked || recordedEntries.isEmpty
            ? nil
            : MedicationSchedule(entries: recordedEntries)

        var medication = Medication(
            id: id,
            name: name,
            dose: dose,
            treatmentClass: treatmentClass,
            category: category,
            dosesPerUnit: dosesPerUnit,
            unitsPerDose: unitsPerDose,
            schedule: schedule,
            lastTakenAt: lastTakenAt,
            todayEventCount: todayEventCount,
            notificationsEnabled: notificationsEnabled ?? true,
            active: active ?? true,
            startsOn: Self.parseCourseDate(startsOn),
            endsOn: Self.parseCourseDate(endsOn),
            oneShot: isOneShot,
            asNeeded: asNeeded ?? false,
            trackIntake: trackIntake,
            recordedSchedule: recordedSchedule,
            deliveryForm: deliveryForm,
            createdAt: createdAt,
            // Nothing is due on a record; the server sends null here already.
            nextDueAt: tracked ? Self.parseNextDueAt(nextDueAt) : nil,
            nextDueOverdue: tracked ? nextDueOverdue : nil,
            liveActivityEnabled: liveActivityEnabled,
            criticalAlarmEnabled: criticalAlarmEnabled,
            trackInjectionSites: trackInjectionSites ?? false,
            allowedInjectionSites: (allowedInjectionSites ?? []).compactMap(InjectionSite.parseAllowedEntry),
            externalSource: externalSource,
            externalId: externalId,
            pausedAt: pausedAt,
            // Propagated verbatim: nil stays nil, 0 stays 0, and nothing here
            // substitutes a derived figure for an absent one.
            stockDosesRemaining: stockDosesRemaining,
            runwayDays: runwayDays,
            courseStatus: courseStatus,
            intakeActionable: intakeActionable
        )
        medication.categoryLabel = categoryLabel
        // MED (#1280): an ended course stops every reminder from its `endedAt`
        // on; the server's `remindersActive` already says so, the fold keeps a
        // row that carries only `endedAt` honest too.
        medication.remindersActive = autoMarkTaken == true || endedAt != nil ? false : remindersActive
        medication.endedAt = endedAt
        medication.canEndCourse = canEndCourse
        medication.canStartCourse = canStartCourse
        medication.autoMarkTakenSince = autoMarkTakenSince
        medication.related = related
        medication.ingredients = ingredients
        medication.hasIngredients = hasIngredients
        medication.autoMarkTaken = autoMarkTaken
        medication.courseCount = courseCount
        medication.previousCourseEndedOn = previousCourseEndedOn
        return medication
    }

    /// Parse the wire `nextDueAt` ISO8601 timestamp (a full instant, not a
    /// `@db.Date` day boundary) into a `Date`. Accepts fractional + plain
    /// ISO8601. Returns `nil` for absent / malformed values (engine fallback).
    static func parseNextDueAt(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        if let date = ISO8601DateFormatter.fractional.date(from: raw) {
            return date
        }
        return ISO8601DateFormatter.plain.date(from: raw)
    }

    /// Parse a wire `YYYY-MM-DD` course-window date into a UTC-midnight
    /// `Date`. The engine interprets these as day boundaries, so a fixed UTC
    /// midnight anchor matches the server's `@db.Date` semantics. Returns
    /// `nil` for absent / malformed values.
    static func parseCourseDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        // Accept both the bare `YYYY-MM-DD` and a full ISO-8601 timestamp
        // (the server may emit either depending on the serializer).
        if let date = ISO8601DateFormatter.plain.date(from: raw) {
            return date
        }
        let parts = raw.prefix(10).split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else
        {
            return nil
        }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar.date(from: components)
    }
}
