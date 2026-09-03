import Foundation
import Testing
#if canImport(UserNotifications) && canImport(UIKit)
    @testable import HealthLog
    import UserNotifications

    /// v0.6.2.3 F1-NOTIF — pins the time-sensitive contract on the four
    /// surfaces that determine whether medication banners (and snoozed
    /// re-fires) break through Focus / Do Not Disturb:
    ///
    /// 1. `authorizationOptions(...)` — the option set we hand to
    ///    `UNUserNotificationCenter.requestAuthorization`. iOS 15
    ///    deprecated the `.timeSensitive` option in favour of the
    ///    `com.apple.developer.usernotifications.time-sensitive`
    ///    entitlement, so the option set must NOT include the deprecated
    ///    member (otherwise warnings-as-errors fails the build); the
    ///    entitlement (set in `HealthLog.entitlements`) is what surfaces
    ///    the Settings → HealthLog → Notifications → "Time-Sensitive
    ///    Notifications" toggle on iOS 15+.
    /// 2. Medication-snooze re-build — `handleMedicationSnooze` must set
    ///    `content.interruptionLevel = .timeSensitive` so the snoozed
    ///    banner inherits the original priority. The regression hazard
    ///    is "snoozing = priority lost".
    /// 3. Mood-snooze re-build — `buildMoodSnoozeRequest` keeps the routine
    ///    `.active` level (Build 273): the evening nudge is `.active` on
    ///    purpose, so a snooze must not escalate it. Historically pinned as
    ///    `.timeSensitive` "for symmetry with
    ///    the server-driven mood reminder push.
    /// 4. Spezi medication banner — the `notificationContent(for:content:)`
    ///    rewrite path in `HealthLogStandard` is covered by an integration
    ///    test in `MedicationsSchedulerModuleTests`; here we cover only
    ///    the local re-build paths because they live inside
    ///    `NotificationService` proper.
    @Suite("NotificationService — time-sensitive interruption-level pinning")
    @MainActor
    struct NotificationServiceTimeSensitiveTests {
        // MARK: - Authorization option set

        /// `UNAuthorizationOptions.timeSensitive` is deprecated since
        /// iOS 15 and emits a compile error under warnings-as-errors.
        /// We pin its absence by checking the rawValue (`1 << 6` per
        /// `UNUserNotificationCenter.h`) so the test compiles cleanly
        /// without referencing the deprecated symbol directly. The
        /// entitlement
        /// `com.apple.developer.usernotifications.time-sensitive` (set
        /// in `HealthLog.entitlements`) is the modern replacement.
        ///
        /// Bit layout (UNUserNotificationCenter.h, iOS 18 SDK):
        /// - 1 << 0  .badge
        /// - 1 << 1  .sound
        /// - 1 << 2  .alert
        /// - 1 << 3  .carPlay
        /// - 1 << 4  .criticalAlert
        /// - 1 << 5  .providesAppNotificationSettings
        /// - 1 << 6  .timeSensitive (deprecated since iOS 15)
        /// - 1 << 7  .provisional
        private static let timeSensitiveOptionRawValue: UInt = 1 << 6

        @Test("authorizationOptions includes the four operator-mandated options without the iOS-15-deprecated .timeSensitive")
        func authorizationOptionsBaseline() {
            let options = NotificationService.authorizationOptions(allowCriticalAlerts: false)
            #expect(options.contains(.alert))
            #expect(options.contains(.sound))
            #expect(options.contains(.badge))
            #expect(options.contains(.providesAppNotificationSettings))
            // Adding the deprecated `.timeSensitive` option to the set
            // would trigger a compile error under warnings-as-errors.
            // Tests pin the absence via the documented rawValue so a
            // future contributor copying an older sample does not
            // silently re-introduce the deprecation.
            #expect(options.rawValue & Self.timeSensitiveOptionRawValue == 0)
            // Critical-alerts stays off unless the operator explicitly opts in.
            #expect(!options.contains(.criticalAlert))
        }

        @Test("authorizationOptions(allowCriticalAlerts: true) adds .criticalAlert without changing the rest")
        func authorizationOptionsCriticalOptIn() {
            let options = NotificationService.authorizationOptions(allowCriticalAlerts: true)
            #expect(options.contains(.criticalAlert))
            #expect(options.contains(.alert))
            #expect(options.contains(.sound))
            #expect(options.contains(.badge))
            #expect(options.contains(.providesAppNotificationSettings))
            #expect(options.rawValue & Self.timeSensitiveOptionRawValue == 0)
        }

        // MARK: - v1.18.4 (#23/#30) foreground SYSTEM_ALERT prominence policy

        /// An urgent illness red-flag "seek care" escalation (`SYSTEM_ALERT` with
        /// a `.timeSensitive` interruption level) is presented with the full loud
        /// set in the foreground so it cannot be missed.
        @Test("Urgent (.timeSensitive) SYSTEM_ALERT gets the loud foreground set")
        func urgentTimeSensitiveSystemAlertIsLoud() {
            let opts = NotificationService.foregroundPresentationOptions(
                interruptionLevel: .timeSensitive,
                eventType: NotificationService.categorySystemAlert
            )
            #expect(opts.contains(.banner))
            #expect(opts.contains(.sound))
            #expect(opts.contains(.list))
        }

        /// A `.critical` SYSTEM_ALERT (operator critical-alert entitlement on)
        /// also gets the loud set — and the policy must never crash on it.
        @Test("Critical SYSTEM_ALERT gets the loud foreground set")
        func criticalSystemAlertIsLoud() {
            let opts = NotificationService.foregroundPresentationOptions(
                interruptionLevel: .critical,
                eventType: NotificationService.categorySystemAlert
            )
            #expect(opts.contains(.banner))
            #expect(opts.contains(.sound))
            #expect(opts.contains(.list))
        }

        /// Graceful degradation: a NON-urgent SYSTEM_ALERT (`.active`, the level
        /// the system resolves to when the critical entitlement is absent AND the
        /// push was not time-sensitive) still surfaces a banner — never dropped.
        @Test("Non-urgent SYSTEM_ALERT still surfaces a banner (graceful)")
        func nonUrgentSystemAlertStillBanners() {
            let opts = NotificationService.foregroundPresentationOptions(
                interruptionLevel: .active,
                eventType: NotificationService.categorySystemAlert
            )
            #expect(opts.contains(.banner))
            #expect(opts.contains(.sound))
            #expect(opts.contains(.list))
        }

        /// A routine push that happens to ride `.timeSensitive` (e.g. a med
        /// reminder) keeps the normal banner — the loud elevation is gated on the
        /// SYSTEM_ALERT event type, not on the level alone.
        @Test("Time-sensitive NON-SYSTEM_ALERT keeps the normal banner set")
        func timeSensitiveNonSystemAlertIsNormal() {
            let opts = NotificationService.foregroundPresentationOptions(
                interruptionLevel: .timeSensitive,
                eventType: NotificationService.categoryMedication
            )
            #expect(opts.contains(.banner))
            #expect(opts.contains(.sound))
            #expect(opts.contains(.list))
        }

        /// A `nil` event type (unparseable / absent) never crashes and falls back
        /// to the base banner set.
        @Test("nil event type degrades to the base banner set without crashing")
        func nilEventTypeDegradesGracefully() {
            let opts = NotificationService.foregroundPresentationOptions(
                interruptionLevel: .passive,
                eventType: nil
            )
            #expect(opts.contains(.banner))
            #expect(opts.contains(.list))
        }

        // MARK: - v0150 C-M1 — urgent path is a REAL escalation (strictly louder)

        /// A `.passive` routine push presents quietly (banner + list, NO sound),
        /// so a low-priority foreground arrival does not chirp. This is the
        /// "base case can be quieter" branch the urgent path must out-shout.
        @Test("Passive routine push is presented quietly (no sound)")
        func passiveRoutinePushIsQuiet() {
            let opts = NotificationService.foregroundPresentationOptions(
                interruptionLevel: .passive,
                eventType: NotificationService.categoryMedication
            )
            #expect(opts.contains(.banner))
            #expect(opts.contains(.list))
            #expect(!opts.contains(.sound))
        }

        /// The urgent SYSTEM_ALERT set must be STRICTLY more prominent than the
        /// base presentation for a push of the SAME (quiet) level — i.e. a proper
        /// superset, not byte-identical. This is the regression guard for the
        /// "elevation was a no-op" defect (C-M1): the urgent path force-adds
        /// `.sound` even on a level the base case mutes.
        @Test("Urgent SYSTEM_ALERT is strictly more prominent than the base set at the same level")
        func urgentIsStrictlyMoreProminentThanBase() {
            let base = NotificationService.foregroundPresentationOptions(
                interruptionLevel: .passive,
                eventType: NotificationService.categoryMedication
            )
            let urgent = NotificationService.foregroundPresentationOptions(
                interruptionLevel: .timeSensitive,
                eventType: NotificationService.categorySystemAlert
            )
            // Strict superset: urgent contains everything base does, AND more.
            #expect(urgent.isSuperset(of: base))
            #expect(urgent != base)
            // Concretely: the extra prominence the base muted is `.sound`.
            #expect(!base.contains(.sound))
            #expect(urgent.contains(.sound))
        }

        /// The urgent path is never DOWNGRADED relative to the loudest routine
        /// path either — it always carries the full alert floor.
        @Test("Urgent SYSTEM_ALERT always carries the full alert floor (never downgraded)")
        func urgentNeverDowngraded() {
            let urgent = NotificationService.foregroundPresentationOptions(
                interruptionLevel: .timeSensitive,
                eventType: NotificationService.categorySystemAlert
            )
            #expect(urgent.contains(.banner))
            #expect(urgent.contains(.list))
            #expect(urgent.contains(.sound))
        }

        // MARK: - Mood snooze re-build keeps the ROUTINE level (Build 273)

        //
        // The evening mood nudge is deliberately `.active` (see
        // `+MoodReminder.swift`, App-Review rationale); a snooze must not
        // escalate it to `.timeSensitive` and break through a Focus the
        // original respected.

        @Test("Mood snooze re-build stays a routine .active reminder")
        func moodSnoozeRebuildIsTimeSensitive() {
            let payload = APNsPayload(
                title: "Wie geht's dir gerade?",
                body: "Logge kurz deine Stimmung.",
                eventType: "MOOD_REMINDER",
                metricType: nil,
                deepLink: nil
            )
            let req = NotificationService.buildMoodSnoozeRequest(payload: payload)
            #expect(req.content.interruptionLevel == .active)
        }

        @Test("Mood snooze re-build stays .active even when payload is nil")
        func moodSnoozeRebuildWithNilPayloadStaysTimeSensitive() {
            let req = NotificationService.buildMoodSnoozeRequest(payload: nil)
            #expect(req.content.interruptionLevel == .active)
        }

        // MARK: - Medication snooze re-build keeps time-sensitive

        /// We test the pure static builder rather than driving the full
        /// `handleMedicationSnooze` round-trip through
        /// `UNUserNotificationCenter`. The host-app-less test runner can
        /// fail `add(_:)` silently when authorization is not granted,
        /// which is exactly why the existing
        /// `NotificationServiceMedicationActionTests
        /// .medSnoozeReschedulesLocally` is on the known-flaky list.
        /// Mirrors the `buildMoodSnoozeRequest` test pattern.
        @Test("Medication snooze re-build content is time-sensitive so snoozed banner breaks through Focus")
        func medicationSnoozeRebuildIsTimeSensitive() {
            let payload = APNsPayload(
                title: "Lisinopril",
                body: "Mittag-Dosis",
                eventType: "MEDICATION_REMINDER",
                metricType: nil,
                deepLink: nil,
                medicationId: "med-time-sensitive",
                scheduleId: "sched-1",
                scheduledFor: Date(timeIntervalSince1970: 1_779_710_400)
            )
            let req = NotificationService.buildMedicationSnoozeRequest(payload: payload)
            #expect(req.content.interruptionLevel == .timeSensitive)
            #expect(req.content.categoryIdentifier == NotificationService.categoryMedication)
            #expect(req.identifier.hasPrefix("snooze-med-time-sensitive-"))
            #expect(req.content.userInfo["medicationId"] as? String == "med-time-sensitive")
            #expect(req.content.userInfo["scheduleId"] as? String == "sched-1")
            if let trigger = req.trigger as? UNTimeIntervalNotificationTrigger {
                #expect(trigger.timeInterval == NotificationService.snoozeIntervalSeconds)
                #expect(!trigger.repeats)
            } else {
                Issue.record("Expected UNTimeIntervalNotificationTrigger on medication snooze")
            }
        }

        @Test("Medication snooze re-build with nil payload still produces a time-sensitive banner")
        func medicationSnoozeRebuildWithNilPayloadStaysTimeSensitive() {
            let req = NotificationService.buildMedicationSnoozeRequest(payload: nil)
            #expect(req.content.interruptionLevel == .timeSensitive)
            #expect(req.content.categoryIdentifier == NotificationService.categoryMedication)
            // Without a payload the builder uses "anon" as the medicationId
            // suffix and produces no userInfo entries — but the banner still
            // breaks through Focus because the operator hit "Snooze".
            #expect(req.identifier.hasPrefix("snooze-anon-"))
        }

        // MARK: - W-B188 lock-screen privacy (snooze re-build)

        /// OFF (default) → the snoozed banner carries the real drug name +
        /// dose from the server payload, exactly as before.
        @Test("Snooze re-build shows the drug name when the lock-screen opt-out is OFF")
        func medicationSnoozeShowsNameWhenPrivacyOff() {
            let payload = APNsPayload(
                title: "Truvada",
                body: "200 mg",
                eventType: "MEDICATION_REMINDER",
                metricType: nil,
                deepLink: nil,
                medicationId: "med-privacy-off",
                scheduleId: "sched-9",
                scheduledFor: Date(timeIntervalSince1970: 1_779_710_400)
            )
            let req = NotificationService.buildMedicationSnoozeRequest(
                payload: payload,
                hideMedicationName: false
            )
            #expect(req.content.title == "Truvada")
            #expect(req.content.body == "200 mg")
            #expect(req.content.userInfo["medicationId"] as? String == "med-privacy-off")
        }

        /// ON → the snoozed banner carries a generic title, no drug name / dose
        /// in the visible text, but the `medicationId` is still in `userInfo`
        /// so the Taken/Snooze/Skip actions keep working.
        @Test("Snooze re-build hides the drug name when the lock-screen opt-out is ON")
        func medicationSnoozeHidesNameWhenPrivacyOn() {
            let payload = APNsPayload(
                title: "Truvada",
                body: "200 mg",
                eventType: "MEDICATION_REMINDER",
                metricType: nil,
                deepLink: nil,
                medicationId: "med-privacy-on",
                scheduleId: "sched-9",
                scheduledFor: Date(timeIntervalSince1970: 1_779_710_400)
            )
            let req = NotificationService.buildMedicationSnoozeRequest(
                payload: payload,
                hideMedicationName: true
            )
            // Generic label — no drug name / dose in the visible text.
            #expect(req.content.title != "Truvada")
            #expect(!req.content.title.contains("Truvada"))
            #expect(!req.content.body.contains("200 mg"))
            #expect(req.content.title == String(localized: "Medication reminder"))
            // Action routing intact — the handler still has the medicationId.
            #expect(req.content.userInfo["medicationId"] as? String == "med-privacy-on")
            #expect(req.content.categoryIdentifier == NotificationService.categoryMedication)
        }
    }

    // MARK: - Spezi medication-content rewrite (P0-2)

    #if canImport(SpeziHealthKit) && canImport(SpeziScheduler)
        /// Spezi medication banners flow through
        /// `HealthLogStandard.notificationContent(for:content:)` before
        /// they hit `UNUserNotificationCenter`. The witness body is
        /// trivially `task.category == .medication`-guarded and then
        /// delegates to the pure
        /// `rewriteMedicationNotificationContent(taskID:content:)`
        /// helper — we test the helper directly because building a real
        /// `SpeziScheduler.Task` would require booting the full Spezi
        /// module graph.
        @Suite("HealthLogStandard — Spezi medication-content rewrite")
        @MainActor
        struct HealthLogStandardMedicationContentTests {
            @Test("Medication banner content is promoted to .timeSensitive so it breaks through Focus")
            func medicationBannerIsTimeSensitive() {
                let taskID = MedicationsSchedulerModule.taskID(medicationID: "med-42", scheduleSlot: 0)
                let content = UNMutableNotificationContent()
                content.title = "Lisinopril"
                content.body = "Morgendliche Dosis"
                HealthLogStandard.rewriteMedicationNotificationContent(taskID: taskID, content: content)
                #expect(content.interruptionLevel == .timeSensitive)
            }

            @Test("Rewrite shapes content for the 3-action MEDICATION_REMINDER chrome")
            func medicationBannerShape() {
                let taskID = MedicationsSchedulerModule.taskID(medicationID: "med-shape", scheduleSlot: 1)
                let content = UNMutableNotificationContent()
                HealthLogStandard.rewriteMedicationNotificationContent(taskID: taskID, content: content)
                #expect(content.categoryIdentifier == NotificationService.categoryMedication)
                #expect(content.badge == nil)
                #expect(content.userInfo["medicationId"] as? String == "med-shape")
                #expect(content.userInfo["speziScheduled"] as? Bool == true)
            }

            // MARK: - W-B188 lock-screen privacy (Spezi rewrite)

            /// OFF (default) → the rewrite leaves the title/body the
            /// scheduler set (the drug name + dose) untouched.
            @Test("Spezi rewrite keeps the drug name when the lock-screen opt-out is OFF")
            func speziRewriteKeepsNameWhenPrivacyOff() {
                LockScreenPrivacy.setHideMedicationName(false)
                defer { LockScreenPrivacy.setHideMedicationName(false) }
                let taskID = MedicationsSchedulerModule.taskID(medicationID: "med-off", scheduleSlot: 0)
                let content = UNMutableNotificationContent()
                content.title = "Truvada"
                content.body = "200 mg"
                HealthLogStandard.rewriteMedicationNotificationContent(taskID: taskID, content: content)
                #expect(content.title == "Truvada")
                #expect(content.body == "200 mg")
                #expect(content.userInfo["medicationId"] as? String == "med-off")
            }

            /// ON → the rewrite replaces the title with a generic localized
            /// label and clears the body, but keeps `medicationId` in
            /// `userInfo` so the intake actions still route.
            @Test("Spezi rewrite hides the drug name when the lock-screen opt-out is ON")
            func speziRewriteHidesNameWhenPrivacyOn() {
                LockScreenPrivacy.setHideMedicationName(true)
                defer { LockScreenPrivacy.setHideMedicationName(false) }
                let taskID = MedicationsSchedulerModule.taskID(medicationID: "med-on", scheduleSlot: 0)
                let content = UNMutableNotificationContent()
                content.title = "Truvada"
                content.body = "200 mg"
                HealthLogStandard.rewriteMedicationNotificationContent(taskID: taskID, content: content)
                // No drug name / dose left in the visible text.
                #expect(content.title != "Truvada")
                #expect(!content.title.contains("Truvada"))
                #expect(content.body.isEmpty)
                #expect(content.title == String(localized: "Medication reminder"))
                // Action routing intact.
                #expect(content.userInfo["medicationId"] as? String == "med-on")
                #expect(content.categoryIdentifier == NotificationService.categoryMedication)
            }
        }
    #endif

#endif
