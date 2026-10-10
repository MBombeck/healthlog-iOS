import Foundation

/// **GH #47 (server v1.28) — Apple Health mirror source-exclusive policy.**
///
/// Split out of `Medication.swift` (file_length discipline) — the stored
/// `externalSource` / `externalId` provenance fields live on the struct; these
/// derived helpers + the provenance-stamp copy live here.
public extension Medication {
    /// `true` when this medication is a read-only mirror of an Apple Health
    /// (HealthKit) medication. A mirrored med is source-exclusive: its doses
    /// come only from Apple Health, so the app must NOT offer manual dose
    /// logging on it (prevents double-counting — compliance is never recomputed
    /// client-side, PROJECT_GUIDE.md).
    var isAppleHealthMirrored: Bool {
        externalSource == IntakeSource.appleHealth.wireValue
    }

    /// `false` for an Apple-Health-mirrored med — the client hides / disables
    /// every manual dose-logging affordance so a dose is never double-counted
    /// against the Apple Health source of truth. `true` for app-managed meds.
    var allowsManualDoseLogging: Bool {
        // v1.39.1 (#1033) — a medication kept as a record offers no intake
        // buttons either: nothing about it is tracked. v1.39.4 (#1040) — nor
        // does one the server calls not actionable today (an ended course).
        !isAppleHealthMirrored && offersIntakeActions
    }

    /// Return a copy stamped with Apple-Health provenance. Used by the mirror
    /// upsert (the server GET/POST responses don't echo `externalSource`, so the
    /// importer is the authority on which med it mirrored).
    func withAppleHealthProvenance(externalId: String?) -> Medication {
        Medication(
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
            notificationsEnabled: notificationsEnabled,
            active: active,
            archivedAt: archivedAt,
            startsOn: startsOn,
            endsOn: endsOn,
            oneShot: oneShot,
            asNeeded: asNeeded,
            trackIntake: trackIntake,
            recordedSchedule: recordedSchedule,
            deliveryForm: deliveryForm,
            createdAt: createdAt,
            nextDueAt: nextDueAt,
            nextDueOverdue: nextDueOverdue,
            liveActivityEnabled: liveActivityEnabled,
            criticalAlarmEnabled: criticalAlarmEnabled,
            trackInjectionSites: trackInjectionSites,
            allowedInjectionSites: allowedInjectionSites,
            externalSource: IntakeSource.appleHealth.wireValue,
            externalId: externalId ?? self.externalId,
            courseStatus: courseStatus,
            intakeActionable: intakeActionable
        ).carryingCategoryLabel(categoryLabel)
    }
}
