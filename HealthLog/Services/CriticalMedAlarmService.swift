#if canImport(AlarmKit)
    import AlarmKit
    import AppIntents
    import Foundation
    import SwiftUI

    /// **v0.9.0 W2/W3 — AlarmKit critical-med alarm service.**
    ///
    /// Thin imperative shell over `AlarmManager.shared` (iOS 26+): the
    /// authorization flow, scheduling relative weekly alarms for opted-in
    /// active meds, cancel/stop, and a reconcile pass. The pure decisions
    /// (eligibility, routing, schedule-mapping, deterministic alarm ids) live
    /// in ``CriticalMedAlarmRouting`` so they unit-test without iOS 26.
    ///
    /// **API pinned against the iOS 26.5 SDK** (`AlarmKit.swiftinterface`):
    /// - `cancel(id:)` / `stop(id:)` are **synchronous `throws`** (NOT async).
    /// - `alarms` is a **throwing computed property** `[Alarm] { get throws }`.
    /// - `schedule(id:configuration:)` is `async throws -> Alarm`.
    /// - `AlarmConfiguration` init takes `(any LiveActivityIntent)?` for
    ///   `stopIntent` / `secondaryIntent` — so the buttons are
    ///   `LiveActivityIntent`s, not plain `AppIntent`s.
    /// - `AlarmPresentation.Alert` non-`stopButton` init requires iOS 26.1;
    ///   the deprecated `stopButton` init covers 26.0 (wrapped so the
    ///   warnings-as-errors build stays clean).
    ///
    /// `@available(iOS 26.0, *)` throughout; callers reach it only through
    /// the version-gated reconcile pass.
    /// The outcome of a ``CriticalMedAlarmService/reconcile(alarmMeds:)`` pass.
    ///
    /// **audit-release 05 C-1 — surface silent scheduling failures.** A
    /// critical-med alarm that fails to arm (auth revoked mid-session, per-app
    /// alarm limit exceeded, config rejected) used to be logged + swallowed with
    /// NO user signal — a life-safety reminder could silently not-arm while the
    /// UI still presented the med as alarm-owned. The reconcile now reports which
    /// medications failed so the caller can thread them to a persistent,
    /// user-visible warning on the medication surface.
    struct CriticalMedAlarmReconcileOutcome {
        /// Medication ids the AlarmKit channel now owns (so the caller can
        /// exclude them from the UN/Spezi scheduler).
        let ownedMedicationIDs: Set<String>
        /// Medication ids for which **at least one** alarm slot failed to (re)arm
        /// on this pass. Empty on a fully-successful reconcile.
        let failedMedicationIDs: Set<String>
    }

    @available(iOS 26.0, *)
    @MainActor
    final class CriticalMedAlarmService {
        /// Shared instance so the out-of-process `MedSnoozeAlarmIntent` can
        /// re-arm a one-shot alarm without an `AppContainer`.
        static let shared = CriticalMedAlarmService()

        /// `AlarmManager.shared` is a non-`Sendable` singleton. We re-fetch it
        /// as a fresh local at each call site rather than storing it, so the
        /// `await schedule/requestAuthorization` sends a region-isolated
        /// local (Swift 6 region-based isolation) instead of a value pinned to
        /// `self`'s MainActor region — no `@unchecked Sendable` needed.
        private var manager: AlarmManager {
            AlarmManager.shared
        }

        /// Snooze interval — parity with the UNNotification path
        /// (`NotificationService.snoozeIntervalSeconds`, 15 min). Duplicated
        /// as a constant here because that symbol is gated behind
        /// `UserNotifications`, and the alarm path must not depend on it.
        nonisolated static let snoozeIntervalSeconds: TimeInterval = 15 * 60

        // MARK: - Authorization

        /// Current AlarmKit authorization state.
        var authorizationState: AlarmManager.AuthorizationState {
            manager.authorizationState
        }

        var isAuthorized: Bool {
            manager.authorizationState == .authorized
        }

        /// Request authorization (prompts only when `.notDetermined`). Called
        /// lazily on the first per-med opt-in, never at launch.
        /// - Returns: `true` when authorized after the flow.
        func requestAuthorizationIfNeeded() async -> Bool {
            switch manager.authorizationState {
            case .authorized:
                return true
            case .denied:
                return false
            case .notDetermined:
                do {
                    let localManager = AlarmManager.shared
                    let state = try await localManager.requestAuthorization()
                    return state == .authorized
                } catch {
                    HLLog.notifications.error(
                        "CriticalMedAlarmService: requestAuthorization failed err=\(LogSanitizer.redact(String(describing: error)), privacy: .public)"
                    )
                    return false
                }
            @unknown default:
                return false
            }
        }

        // MARK: - Reconcile

        /// Reconcile the AlarmKit alarm set against the supplied medications.
        /// Schedules/refreshes alarms for the alarm-owned meds and cancels
        /// alarms for any med no longer eligible (toggle off, archived,
        /// notifications off, downgraded schedule).
        ///
        /// Idempotent: `schedule(id:)` with a stable id replaces the prior
        /// alarm, so a re-run with unchanged input is a no-op. A scheduling
        /// failure never blocks the medication load path — but it is no longer
        /// invisible: the failed medication ids ride back in the
        /// ``CriticalMedAlarmReconcileOutcome`` so the caller can raise a
        /// persistent user-facing warning (C-1).
        @discardableResult
        func reconcile(
            alarmMeds: [Medication]
        ) async -> CriticalMedAlarmReconcileOutcome {
            let scheduled = await scheduleDesired(alarmMeds: alarmMeds)
            cancelOrphans(keeping: scheduled.desiredIDs, activeMedIDs: alarmMeds.map(\.id))
            return CriticalMedAlarmReconcileOutcome(
                ownedMedicationIDs: Set(alarmMeds.map(\.id)),
                failedMedicationIDs: scheduled.failedMedicationIDs
            )
        }

        /// Schedule (or refresh) every alarm slot for the alarm-owned meds.
        /// Returns the set of `Alarm.ID`s now desired plus the ids of any
        /// medication whose alarm(s) failed to arm (C-1).
        private func scheduleDesired(
            alarmMeds: [Medication]
        ) async -> (desiredIDs: Set<UUID>, failedMedicationIDs: Set<String>) {
            var desired: Set<UUID> = []
            var failedMedicationIDs: Set<String> = []
            for medication in alarmMeds {
                // v0.10 R1 §3.5 — route every cadence through the generalised
                // planner: recurring weekly slots stay recurring; rolling /
                // monthly / yearly / biweekly land as single-shot .fixed
                // alarms at the engine's next occurrence (re-armed each
                // reconcile / intake).
                let planned = CriticalMedAlarmRouting.plannedAlarms(for: medication)
                for (index, plan) in planned.enumerated() {
                    let id = CriticalMedAlarmRouting.alarmID(
                        medicationID: medication.id,
                        slotIndex: index
                    )
                    desired.insert(id)
                    let armed = await schedulePlan(id: id, medication: medication, plan: plan)
                    if !armed {
                        // C-1 — any slot failing marks the whole med as not
                        // reliably armed so the user warning names it.
                        failedMedicationIDs.insert(medication.id)
                    }
                }
            }
            return (desired, failedMedicationIDs)
        }

        /// `nonisolated` for the same region-isolation reason as
        /// `scheduleSlot` — builds + schedules the alarm in a disconnected
        /// region from `Sendable` value inputs.
        /// - Returns: `true` when the alarm armed, `false` when scheduling threw.
        private nonisolated func schedulePlan(
            id: UUID,
            medication: Medication,
            plan: CriticalMedAlarmRouting.PlannedAlarm
        ) async -> Bool {
            switch plan {
            case let .weekly(slot):
                await scheduleSlot(id: id, medication: medication, slot: slot)
            case let .fixed(fireDate):
                await scheduleFixed(id: id, medication: medication, fireDate: fireDate)
            }
        }

        /// Schedule a single-shot `.fixed` alarm for a low-frequency / rolling
        /// cadence. The stop/snooze intents carry the actual fire instant as
        /// `scheduledFor` so the server intake row aligns with the dose.
        /// - Returns: `true` when the alarm armed, `false` when scheduling threw.
        private nonisolated func scheduleFixed(
            id: UUID,
            medication: Medication,
            fireDate: Date
        ) async -> Bool {
            do {
                let localManager = AlarmManager.shared
                let config = Self.buildFixedConfiguration(medication: medication, fireDate: fireDate)
                _ = try await localManager.schedule(id: id, configuration: config)
                return true
            } catch {
                HLLog.notifications.error(
                    "CriticalMedAlarmService: fixed schedule failed medId=\(medication.id, privacy: .private(mask: .hash)) err=\(LogSanitizer.redact(String(describing: error)), privacy: .public)"
                )
                return false
            }
        }

        /// `nonisolated` so the `AlarmConfiguration` (which embeds the
        /// non-`Sendable` AppIntents) is built + scheduled entirely inside a
        /// disconnected region — never crossing out of the MainActor's
        /// region, so Swift 6 region isolation permits the `await schedule`
        /// send without `@unchecked Sendable`. The `medication` / `slot`
        /// inputs are `Sendable` value types so passing them in is safe.
        /// - Returns: `true` when the alarm armed, `false` when scheduling threw.
        private nonisolated func scheduleSlot(
            id: UUID,
            medication: Medication,
            slot: CriticalMedAlarmRouting.AlarmSlot
        ) async -> Bool {
            do {
                let localManager = AlarmManager.shared
                let config = Self.buildConfiguration(medication: medication, slot: slot)
                _ = try await localManager.schedule(id: id, configuration: config)
                return true
            } catch {
                HLLog.notifications.error(
                    "CriticalMedAlarmService: schedule failed medId=\(medication.id, privacy: .private) err=\(LogSanitizer.redact(String(describing: error)), privacy: .private)"
                )
                return false
            }
        }

        /// Cancel every HealthLog-owned alarm that is genuinely orphaned.
        /// Mirrors the Spezi scheduler's orphan-purge but — crucially — does
        /// NOT purge the pending snooze alarm (slot
        /// ``CriticalMedAlarmRouting/snoozeSlotIndex``) of a med that is still
        /// alarm-owned: a routine reconcile (load / foreground / intake change)
        /// must not silently drop a user's pending snooze (HIGH-1). The orphan
        /// decision is the pure ``CriticalMedAlarmRouting/orphanIDs(existing:desiredScheduledIDs:activeMedIDs:)``.
        /// The `alarms` property is throwing (not async) per the SDK.
        private func cancelOrphans(keeping desiredIDs: Set<UUID>, activeMedIDs: [String]) {
            let existing: [Alarm]
            do {
                existing = try manager.alarms
            } catch {
                HLLog.notifications.error(
                    "CriticalMedAlarmService: alarms read failed err=\(LogSanitizer.redact(String(describing: error)), privacy: .public)"
                )
                return
            }
            let orphans = CriticalMedAlarmRouting.orphanIDs(
                existing: existing.map(\.id),
                desiredScheduledIDs: desiredIDs,
                activeMedIDs: activeMedIDs
            )
            for id in orphans {
                cancel(id: id)
            }
        }

        // MARK: - Cancel / Stop

        private func cancel(id: UUID) {
            do {
                try manager.cancel(id: id)
            } catch {
                // A cancel for an id that doesn't exist is expected during
                // the slot-ceiling sweep — log at debug, don't surface.
                HLLog.notifications.debug(
                    "CriticalMedAlarmService: cancel id=\(id.uuidString, privacy: .private) err=\(LogSanitizer.redact(String(describing: error)), privacy: .private)"
                )
            }
        }

        // MARK: - Snooze (out-of-process)

        /// Re-arm a one-shot alarm `snoozeIntervalSeconds` later for the
        /// snoozed dose. Called by `MedSnoozeAlarmIntent.perform()` (out of
        /// process). Uses a `.fixed` schedule (absolute fire instant) since a
        /// snooze is a one-time deferral, not a recurrence.
        func snooze(
            medicationId: String,
            medicationName: String,
            dose: String,
            scheduledFor: Date
        ) async {
            guard isAuthorized else { return }
            await scheduleSnoozeAlarm(
                medicationId: medicationId,
                medicationName: medicationName,
                dose: dose,
                scheduledFor: scheduledFor
            )
        }

        /// `nonisolated` for the same region-isolation reason as
        /// `scheduleSlot` — builds + schedules the one-shot snooze alarm in a
        /// disconnected region from `Sendable` value inputs.
        private nonisolated func scheduleSnoozeAlarm(
            medicationId: String,
            medicationName: String,
            dose: String,
            scheduledFor: Date
        ) async {
            let fireDate = Date().addingTimeInterval(Self.snoozeIntervalSeconds)
            let id = CriticalMedAlarmRouting.snoozeAlarmID(medicationID: medicationId)
            do {
                let localManager = AlarmManager.shared
                let config = Self.buildSnoozeConfiguration(
                    medicationId: medicationId,
                    medicationName: medicationName,
                    dose: dose,
                    scheduledFor: scheduledFor,
                    fireDate: fireDate
                )
                _ = try await localManager.schedule(id: id, configuration: config)
            } catch {
                HLLog.notifications.error(
                    "CriticalMedAlarmService: snooze schedule failed err=\(LogSanitizer.redact(String(describing: error)), privacy: .public)"
                )
            }
        }

        // MARK: - Configuration builders (pure given the SDK types)

        /// Build the recurring weekly alarm configuration for a med slot.
        nonisolated static func buildConfiguration(
            medication: Medication,
            slot: CriticalMedAlarmRouting.AlarmSlot
        ) -> AlarmManager.AlarmConfiguration<MedAlarmMetadata> {
            let recurrence: Alarm.Schedule.Relative.Recurrence = slot.weekdays.isEmpty
                ? .weekly(Self.everyDay) // no weekday constraint → all 7 days
                : .weekly(slot.weekdays.map(Self.localeWeekday(from:)))
            let schedule = Alarm.Schedule.relative(
                Alarm.Schedule.Relative(
                    time: Alarm.Schedule.Relative.Time(hour: slot.hour, minute: slot.minute),
                    repeats: recurrence
                )
            )
            let scheduledFor = nextFireInstant(
                hour: slot.hour,
                minute: slot.minute,
                weekdays: slot.weekdays
            )
            return assembleConfiguration(
                schedule: schedule,
                medicationId: medication.id,
                medicationName: medication.name,
                dose: medication.dose,
                scheduledFor: scheduledFor
            )
        }

        /// **v0.10 R1 §3.5 — build a single-shot `.fixed` alarm configuration**
        /// for a rolling / monthly / yearly / biweekly cadence. The fire
        /// instant is the engine's next occurrence; the stop/snooze intents
        /// carry it as `scheduledFor` so the server intake row aligns with the
        /// dose. Re-armed on each reconcile / intake (the next due re-anchors
        /// for rolling cadences).
        nonisolated static func buildFixedConfiguration(
            medication: Medication,
            fireDate: Date
        ) -> AlarmManager.AlarmConfiguration<MedAlarmMetadata> {
            assembleConfiguration(
                schedule: .fixed(fireDate),
                medicationId: medication.id,
                medicationName: medication.name,
                dose: medication.dose,
                scheduledFor: fireDate
            )
        }

        /// Build the one-shot snooze alarm configuration.
        nonisolated static func buildSnoozeConfiguration(
            medicationId: String,
            medicationName: String,
            dose: String,
            scheduledFor: Date,
            fireDate: Date
        ) -> AlarmManager.AlarmConfiguration<MedAlarmMetadata> {
            assembleConfiguration(
                schedule: .fixed(fireDate),
                medicationId: medicationId,
                medicationName: medicationName,
                dose: dose,
                scheduledFor: scheduledFor
            )
        }

        /// Shared assembler: build an `AlarmConfiguration` from a schedule +
        /// the dose metadata + the `scheduledFor` instant the stop/snooze
        /// intents carry. Single source for the recurring / fixed / snooze
        /// builders so they don't drift.
        private nonisolated static func assembleConfiguration(
            schedule: Alarm.Schedule,
            medicationId: String,
            medicationName: String,
            dose: String,
            scheduledFor: Date
        ) -> AlarmManager.AlarmConfiguration<MedAlarmMetadata> {
            let metadata = MedAlarmMetadata(
                medicationId: medicationId,
                medicationName: medicationName,
                dose: dose
            )
            return AlarmManager.AlarmConfiguration<MedAlarmMetadata>(
                schedule: schedule,
                attributes: buildAttributes(metadata: metadata),
                stopIntent: MedTakenAlarmIntent(
                    medicationId: medicationId,
                    scheduledFor: scheduledFor
                ),
                secondaryIntent: MedSnoozeAlarmIntent(
                    medicationId: medicationId,
                    scheduledFor: scheduledFor,
                    medicationName: medicationName,
                    dose: dose
                ),
                sound: .default
            )
        }

        private nonisolated static func buildAttributes(
            metadata: MedAlarmMetadata
        ) -> AlarmAttributes<MedAlarmMetadata> {
            let stopButton = AlarmButton(
                text: "alarm.action.taken",
                textColor: .white,
                systemImageName: "checkmark.circle.fill"
            )
            let snoozeButton = AlarmButton(
                text: "alarm.action.snooze",
                textColor: .white,
                systemImageName: "clock"
            )
            let title = alertTitle(name: metadata.medicationName, dose: metadata.dose)
            let alert = buildAlert(title: title, stop: stopButton, secondary: snoozeButton)
            return AlarmAttributes<MedAlarmMetadata>(
                presentation: AlarmPresentation(alert: alert),
                metadata: metadata,
                // b146 — monochrome doctrine: alarm accent was purple; use the
                // neutral primary tint (never lila).
                tintColor: HLText.primary
            )
        }

        /// The localized alarm title carrying the medication name (+ dose when
        /// present) so a multi-med user knows *which* alarm fired — the loud
        /// breakthrough alert is otherwise ambiguous (QA-design / i18n #5).
        /// Falls back to the generic "Medikament fällig" key when the name is
        /// empty (defensive — schedule-time metadata always has a name).
        private nonisolated static func alertTitle(name: String, dose: String) -> LocalizedStringResource {
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty else { return "alarm.med.title" }
            let trimmedDose = dose.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedDose.isEmpty {
                return "\(trimmedName) due"
            }
            return "\(trimmedName) (\(trimmedDose)) due"
        }

        /// Build the alert presentation. The non-`stopButton` init is iOS
        /// 26.1+; below that the deprecated `stopButton` init is the only
        /// option, so we wrap it in a deprecation-scoped helper to keep the
        /// warnings-as-errors build clean.
        private nonisolated static func buildAlert(
            title: LocalizedStringResource,
            stop: AlarmButton,
            secondary: AlarmButton
        ) -> AlarmPresentation.Alert {
            if #available(iOS 26.1, *) {
                return AlarmPresentation.Alert(
                    title: title,
                    secondaryButton: secondary,
                    secondaryButtonBehavior: .custom
                )
            }
            return alertWithDeprecatedStopButton(title: title, stop: stop, secondary: secondary)
        }

        @available(iOS, deprecated: 26.1, message: "stopButton init only needed on iOS 26.0")
        private nonisolated static func alertWithDeprecatedStopButton(
            title: LocalizedStringResource,
            stop: AlarmButton,
            secondary: AlarmButton
        ) -> AlarmPresentation.Alert {
            AlarmPresentation.Alert(
                title: title,
                stopButton: stop,
                secondaryButton: secondary,
                secondaryButtonBehavior: .custom
            )
        }

        // MARK: - Helpers

        /// All seven weekdays — `Locale.Weekday` is not `CaseIterable`, so we
        /// enumerate explicitly for the "fires every day" recurrence.
        private nonisolated static let everyDay: [Locale.Weekday] = [
            .sunday, .monday, .tuesday, .wednesday, .thursday, .friday, .saturday
        ]

        /// Map our `Weekday` (Sun=0…Sat=6) onto `Locale.Weekday`.
        nonisolated static func localeWeekday(from weekday: Weekday) -> Locale.Weekday {
            switch weekday {
            case .sun: .sunday
            case .mon: .monday
            case .tue: .tuesday
            case .wed: .wednesday
            case .thu: .thursday
            case .fri: .friday
            case .sat: .saturday
            }
        }

        /// The next wall-clock instant matching `hour:minute` **on a weekday in
        /// `weekdays`** from now — used as the intents' `scheduledFor` so the
        /// server intake row aligns with the dose the alarm actually fires
        /// (MEDIUM-4). For a Mon/Wed/Fri med a Tuesday reconcile must stamp
        /// Wednesday HH:MM, not Tuesday. Empty `weekdays` = "every day"
        /// (matches the `.weekly(everyDay)` recurrence).
        nonisolated static func nextFireInstant(
            hour: Int,
            minute: Int,
            weekdays: [Weekday] = [],
            now: Date = .now,
            calendar: Calendar = .current
        ) -> Date {
            // Candidate at the target time today.
            let todayAtTime = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now) ?? now
            // Allowed weekday integers in Calendar's 1=Sun…7=Sat convention.
            let allowed: Set<Int> = weekdays.isEmpty
                ? Set(1 ... 7)
                : Set(weekdays.map { $0.rawValue + 1 })
            // Scan up to 7 days for the next allowed weekday whose target
            // time is still in the future (today only if it hasn't passed).
            for offset in 0 ... 7 {
                guard let day = calendar.date(byAdding: .day, value: offset, to: todayAtTime) else { continue }
                guard day > now else { continue }
                if allowed.contains(calendar.component(.weekday, from: day)) {
                    return day
                }
            }
            return todayAtTime
        }
    }
#endif
