import Foundation
import os
#if canImport(UserNotifications)
    import UserNotifications
#endif

/// Puts a silenced reminder back when its dose opens again.
///
/// ``MedicationReminderCompletion`` closes the SpeziScheduler event of every
/// slot the today list shows as taken or skipped, already on the optimistic
/// patch. SpeziScheduler cannot reopen an event. A slot that turns open again
/// (undo, a rollback after a refused save, any other way back) would therefore
/// stay without its reminder. For such a slot whose time still lies ahead a
/// one-off local notification takes the reminder's place: same content,
/// category and actions, an identifier derived from medication and slot. It
/// goes again (pending and delivered) once the dose is recorded.
enum MedicationReminderReopen {
    /// A dose slot, cut to the minute so the optimistic row and the server's
    /// answer name the same slot.
    struct Slot: Hashable, Codable, Sendable {
        let medicationId: String
        let scheduledAt: Date

        init(medicationId: String, scheduledAt: Date) {
            self.medicationId = medicationId
            self.scheduledAt = Date(timeIntervalSince1970: (scheduledAt.timeIntervalSince1970 / 60).rounded(.down) * 60)
        }
    }

    /// What one pass does.
    struct Plan: Equatable {
        /// Reopened slots ahead of now: arm the one-off notification.
        var schedule: [Slot] = []
        /// Slots recorded again whose one-off notification is armed: remove it.
        var remove: [Slot] = []
        /// Slots whose reminder is silenced after this pass.
        var silenced: Set<Slot> = []
        /// Slots with an armed one-off notification after this pass.
        var armed: Set<Slot> = []

        /// The plan a device may carry out. A device that does not plan local
        /// reminders (an iPad next to an active iPhone) only removes, never arms.
        func restricted(plansLocally: Bool) -> Plan {
            guard !plansLocally else { return self }
            var copy = self
            copy.schedule = []
            return copy
        }
    }

    /// How long a slot is remembered after its time.
    static let memory: TimeInterval = 36 * 60 * 60

    /// Pure rule.
    static func plan(
        resolved: [Slot],
        open: [Slot],
        silenced: Set<Slot>,
        armed: Set<Slot>,
        now: Date
    ) -> Plan {
        var plan = Plan(silenced: silenced, armed: armed)
        for slot in resolved {
            plan.silenced.insert(slot)
            if plan.armed.remove(slot) != nil { plan.remove.append(slot) }
        }
        for slot in open where plan.silenced.contains(slot) {
            plan.silenced.remove(slot)
            if slot.scheduledAt > now, plan.armed.insert(slot).inserted {
                plan.schedule.append(slot)
            }
        }
        plan.silenced = plan.silenced.filter { now.timeIntervalSince($0.scheduledAt) <= memory }
        plan.armed = plan.armed.filter { now.timeIntervalSince($0.scheduledAt) <= memory }
        return plan
    }

    /// Slots of the today list that are still to be taken.
    static func openSlots(in intakes: [MedicationIntake]) -> [Slot] {
        intakes
            .filter { $0.status == .pending || $0.status == .snoozed || $0.status == .missed }
            .map { Slot(medicationId: $0.medicationId, scheduledAt: $0.scheduledAt) }
    }

    /// Slots of the today list that are taken or skipped.
    static func resolvedSlots(in intakes: [MedicationIntake]) -> [Slot] {
        intakes
            .filter { $0.status == .taken || $0.status == .skipped }
            .map { Slot(medicationId: $0.medicationId, scheduledAt: $0.scheduledAt) }
    }

    /// Deterministic per medication and slot; outside SpeziScheduler's prefix,
    /// so its re-planning never removes it.
    static func identifier(for slot: Slot) -> String {
        "dev.healthlog.med.reopen.\(slot.medicationId).\(Int(slot.scheduledAt.timeIntervalSince1970))"
    }

    // MARK: - State

    private struct State: Codable, Sendable {
        var silenced: Set<Slot> = []
        var armed: Set<Slot> = []
    }

    private static let url: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
        .appendingPathComponent("HealthLog", isDirectory: true)
        .appendingPathComponent("medication-reminder-reopen.json", isDirectory: false)

    private static let state = OSAllocatedUnfairLock<State>(initialState: url
        .flatMap { try? Data(contentsOf: $0) }
        .flatMap { try? JSONDecoder().decode(State.self, from: $0) } ?? State())

    /// Runs the plan against the stored state and returns it. Medication ids
    /// and slot instants only.
    static func advance(resolved: [Slot], open: [Slot], now: Date) -> Plan {
        state.withLock { current in
            let next = plan(resolved: resolved, open: open, silenced: current.silenced, armed: current.armed, now: now)
            current = State(silenced: next.silenced, armed: next.armed)
            persist(current)
            return next
        }
    }

    private static func persist(_ snapshot: State) {
        guard let url else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(snapshot)
                .write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            HLLog.notifications.error("Reminder reopen state write failed")
        }
    }

    /// Logout: forget the slots and take back every armed one-off reminder.
    static func clearOnLogout() {
        let armed = state.withLock { current in
            let armed = current.armed
            current = State()
            persist(current)
            return armed
        }
        #if canImport(UserNotifications)
            let ids = armed.map(identifier(for:))
            let center = UNUserNotificationCenter.current()
            center.removePendingNotificationRequests(withIdentifiers: ids)
            center.removeDeliveredNotifications(withIdentifiers: ids)
        #endif
    }
}

#if canImport(UserNotifications)
    extension MedicationReminderReopen {
        /// The one-off reminder: the regular reminder's text (name and dose,
        /// or the neutral label when names stay off the lock screen), its
        /// category and actions, and the slot itself in `userInfo`.
        @MainActor
        static func content(for medication: Medication, slot: Slot) -> UNMutableNotificationContent {
            let content = UNMutableNotificationContent()
            if LockScreenPrivacy.hideMedicationName() {
                content.title = String(localized: "Medication reminder")
            } else {
                content.title = medication.name
                content.body = medication.dose
            }
            content.sound = .default
            content.interruptionLevel = .timeSensitive
            content.categoryIdentifier = RelayCategoryIdentity.medication()
            content.userInfo = NotificationService.medicationUserInfo(
                medicationId: medication.id,
                scheduleId: nil,
                scheduledFor: slot.scheduledAt
            )
            // Hide content in notifications: only the neutral text is stored.
            NotificationContentPrivacy.apply(to: content, kind: .reminder)
            return content
        }

        /// Applies a plan to the notification center.
        @MainActor
        static func apply(_ plan: Plan, medications: [Medication], plansLocally: Bool = true, now: Date = .now) {
            let plan = plan.restricted(plansLocally: plansLocally)
            let center = UNUserNotificationCenter.current()
            let removed = plan.remove.map(identifier(for:))
            if !removed.isEmpty {
                center.removePendingNotificationRequests(withIdentifiers: removed)
                center.removeDeliveredNotifications(withIdentifiers: removed)
            }
            for slot in plan.schedule {
                guard let medication = medications.first(where: { $0.id == slot.medicationId }) else { continue }
                let request = UNNotificationRequest(
                    identifier: identifier(for: slot),
                    content: content(for: medication, slot: slot),
                    trigger: UNTimeIntervalNotificationTrigger(
                        timeInterval: max(1, slot.scheduledAt.timeIntervalSince(now)),
                        repeats: false
                    )
                )
                center.add(request) { error in
                    if error != nil { HLLog.notifications.error("Reminder reopen: add failed") }
                }
            }
        }
    }
#endif
