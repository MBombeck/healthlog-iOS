import Foundation

/// **MED-PLUS (1.5.0, #126 3.11) — "record doses automatically" and the
/// reminder state, as the server publishes them (v1.42.2).**
///
/// With `autoMarkTaken` on, the server records every scheduled dose as taken
/// shortly after its time, from `autoMarkTakenSince` on; a dose the person
/// logged, skipped or removed is never touched. No reminder goes out for such a
/// medication on any channel, and the local planner arms none either:
/// `toDomain()` folds `autoMarkTaken: true` into `remindersActive: false`, which
/// ``MedicationReminderDeliveryPolicy/plansLocalReminder(for:)`` reads. So the
/// switch never adds a reminder, it can only take one away.
///
/// A server without the field (`autoMarkTaken == nil`) gets no switch and is
/// never sent the key.
public extension Medication {
    /// Whether the editor offers the switch: the server knows the field, the
    /// medication has scheduled doses to record (not as needed, intake tracked,
    /// as on the web), and the caller may change its medications.
    func offersAutoMarkTakenSwitch(canManage: Bool) -> Bool {
        autoMarkTaken != nil && canManage && !asNeeded && tracksIntake
    }

    /// Whether the existing dose subtitle of the detail page adds "no
    /// reminders": only when the server says so (`remindersActive == false`)
    /// for a medication that would otherwise remind. A paused, ended, as-needed
    /// or record-only medication already says why nothing is due.
    var saysNoReminders: Bool {
        remindersActive == false && active && tracksIntake && !asNeeded
            && !hasEndedCourseNow && courseStatus != .ended
    }
}

public extension AccountAccess {
    /// Whether the record in use lets the caller change medications: always on
    /// their own record, on a shared one only with a write grant that reaches
    /// medications (the level the medication's PUT asks for).
    var canManageMedications: Bool {
        guard let active else { return true }
        return active.allows(section: .medications, write: true)
    }
}

/// The editor's switch: as shown, and the server's own value (`nil` when the
/// server does not know the field; the switch is then neither shown nor sent).
struct MedicationAutoMarkTakenFormValue: Equatable {
    var isOn = false
    var server: Bool?

    init(isOn: Bool = false, server: Bool? = nil) {
        self.isOn = isOn
        self.server = server
    }

    init(from medication: Medication) {
        self.init(isOn: medication.autoMarkTaken == true, server: medication.autoMarkTaken)
    }

    /// The value the PUT names: only a change against the server's own value.
    var write: Bool? {
        guard let server, isOn != server else { return nil }
        return isOn
    }
}
