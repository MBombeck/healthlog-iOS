import Foundation

extension MedicationsStore {
    /// Minimum gap between foreground-triggered forced loads. Short enough that
    /// a real resume after a glance still revalidates promptly, long enough to
    /// swallow a multi-event scenePhase flap.
    static let foregroundRevalidateThrottle: TimeInterval = 3

    /// What the local planners reconcile against. A device that does not plan
    /// reminders (an iPad next to an active iPhone, ``ReminderDevicePolicy``)
    /// reconciles against nothing, which cancels whatever it armed earlier.
    var plannedMedications: [Medication] {
        localPlanningGate?() ?? true ? medications : []
    }
}
