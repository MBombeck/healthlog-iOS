import Foundation
#if canImport(UserNotifications)
    import UserNotifications
#endif
#if canImport(UIKit)
    import UIKit
#endif

#if canImport(UserNotifications) && canImport(UIKit)

    // MARK: - UNUserNotificationCenterDelegate

    @MainActor
    extension NotificationService: UNUserNotificationCenterDelegate {
        /// **v0.7.0 W-SEC-M-2 — defensive allowlist for `medicationId`
        /// arriving via APNs userInfo.**
        ///
        /// `DeepLinkRoute.idAllowlist` covers IDs that travel through a
        /// `healthlog://medications/<id>` URL, but a `medicationId`
        /// pulled straight from an APN payload bypasses that gate:
        /// `recordFromReminder` accepts whatever string the server (or a
        /// tampered/mock APN) sends. Mirror the same shape (cuid2 / med_
        /// / UUID — short alnum + `_` + `-`, max 64 chars) so a bogus ID
        /// can never reach the repository POST body. Failure logs at
        /// `error` level + falls back to the deep-link path.
        static let medicationIdAllowlist: NSRegularExpression? = try? NSRegularExpression(
            pattern: "^[A-Za-z0-9_-]{1,64}$",
            options: []
        )

        /// Returns the input only when it matches the medication-ID
        /// allowlist regex. `nil` means the caller must drop the action
        /// (callers fall back to a deep-link, never silently to a
        /// no-medicationId POST).
        static func validatedMedicationId(_ candidate: String?) -> String? {
            guard let candidate, let regex = medicationIdAllowlist else { return nil }
            let range = NSRange(candidate.startIndex..., in: candidate)
            return regex.firstMatch(in: candidate, options: [], range: range) == nil ? nil : candidate
        }

        nonisolated func userNotificationCenter(
            _: UNUserNotificationCenter,
            willPresent notification: UNNotification
        ) async -> UNNotificationPresentationOptions {
            // Foreground: Banner + Sound. Medikamenten-Reminder sind
            // zeit-kritisch — ein silent-swallow wäre User-feindlich.
            //
            // v0.6.1.3 Y4.1 — `.badge` is intentionally dropped from
            // the foreground-presentation set. The App-Badge is now
            // driven centrally from `MedicationsStore.dueOrMissedCount`;
            // letting the OS auto-bump on every foreground arrival
            // would double-count against the centrally pushed value.
            let content = notification.request.content
            let userInfo = content.userInfo
            let wrapped = RemoteNotificationUserInfo(userInfo)
            let payload = APNsPayload.parse(userInfo: wrapped.raw)
            // v0.6.1.3 Y4.1 — a med reminder that arrives in the
            // foreground means a new dose just rolled into the due
            // window. Recompute the badge so the icon reflects the new
            // "due" state immediately, before the user even acts on the
            // banner. Idempotent for non-medication categories — the
            // store snapshot stays unchanged.
            if payload?.eventType == Self.categoryMedication {
                await refreshBadgeFromAttachedStoreIfAvailable()
            }
            // v0.14.1 notifications-bug H2 — the evening mood reminder is now a
            // repeating daily trigger (no background re-arm), so the "already
            // logged today → don't nag" gate lives here instead of at scheduling
            // time: if the mood nudge arrives while the app is foreground and a
            // mood entry already exists for today, suppress the banner. (In the
            // background iOS delivers it directly — the accepted H2 tradeoff:
            // reliability over the rare, harmless already-logged double-nudge.)
            if payload?.eventType == Self.categoryMood, await moodAlreadyLoggedToday() {
                return []
            }
            // v1.18.4 (#23/#30) — elevate an urgent illness red-flag "seek care"
            // escalation (a `SYSTEM_ALERT` arriving with a `.timeSensitive` /
            // `.critical` interruption level) so it cuts through even in the
            // foreground. The pure policy keeps the system-/operator-entitlement
            // degradation testable + crash-free (see `foregroundPresentationOptions`).
            return Self.foregroundPresentationOptions(
                interruptionLevel: content.interruptionLevel,
                eventType: payload?.eventType
            )
        }

        /// **Pure foreground-presentation policy (v1.18.4 / #23/#30, v0150 C-M1).**
        ///
        /// Maps a notification's interruption level + event type to the option
        /// set the `willPresent` delegate returns.
        ///
        /// **Base (routine) path.** A foreground push surfaces a banner + list.
        /// A `.passive` push (the system's "don't interrupt" level) is presented
        /// quietly — banner + list, **no sound** — so a low-priority foreground
        /// arrival does not chirp; every other routine level keeps the banner +
        /// list + sound. `.badge` stays centrally driven (`MedicationsStore`).
        ///
        /// **Urgent escalation.** An illness red-flag "seek care" escalation — a
        /// `SYSTEM_ALERT` whose payload carries `aps.interruption-level:
        /// time-sensitive` (or `critical` only when the operator's
        /// `APNS_CRITICAL_ENTITLEMENT` is on) — is ALWAYS presented with the full
        /// `[.banner, .list, .sound]` set and is never downgraded. This is a real
        /// escalation, not a relabel: it force-adds `.sound` even on a path the
        /// base case would mute, so the urgent set is a strict superset of base
        /// whenever the base case is quieter.
        ///
        /// **Graceful degradation.** No new payload key is read — we branch on
        /// the OS-resolved `interruptionLevel`. When the Critical Alerts
        /// entitlement is NOT on the build, the system has already demoted a
        /// `.critical` push to `.timeSensitive` before it reaches us, so this
        /// policy simply sees `.timeSensitive` and still elevates — it never
        /// assumes the entitlement and never crashes / drops the alert. The
        /// system layers the critical-alert audio on top automatically when the
        /// entitlement IS present; the loud `[.banner, .list, .sound]` floor here
        /// is the strongest lever we have without it.
        nonisolated static func foregroundPresentationOptions(
            interruptionLevel: UNNotificationInterruptionLevel,
            eventType: String?
        ) -> UNNotificationPresentationOptions {
            let isUrgentLevel = interruptionLevel == .timeSensitive || interruptionLevel == .critical
            // An urgent SYSTEM_ALERT is the illness "seek care" escalation. We
            // gate on BOTH the level AND the event type so a routine push that
            // happens to ride `.timeSensitive` (e.g. a med reminder) keeps the
            // routine path — only the clinical escalation gets the always-alert
            // floor. The urgent set is never downgraded.
            if isUrgentLevel, eventType == categorySystemAlert {
                return [.banner, .list, .sound]
            }
            // Routine path. `.passive` (the OS "stay quiet" level) presents
            // without sound; every other level banners + sounds + lists. This is
            // what lets the urgent escalation be STRICTLY more prominent than a
            // quiet routine push (which it would not be if base always sounded).
            if interruptionLevel == .passive {
                return [.banner, .list]
            }
            return [.banner, .list, .sound]
        }

        nonisolated func userNotificationCenter(
            _: UNUserNotificationCenter,
            didReceive response: UNNotificationResponse
        ) async {
            let userInfo = response.notification.request.content.userInfo
            let wrapped = RemoteNotificationUserInfo(userInfo)
            let actionID = response.actionIdentifier
            let payload = Self.resolvedPayload(
                userInfo: wrapped.raw,
                deliveredAt: response.notification.date
            )
            // eventType/actionID are fixed routing constants (enum-grade), no user data.
            // swiftlint:disable:next hllog_public_privacy_interpolation
            HLLog.notifications.info(
                "Push-Tap eventType=\(payload?.eventType ?? "nil", privacy: .public) action=\(actionID, privacy: .public) hasMedicationId=\(payload?.medicationId != nil)"
            )
            // Dispatch by category action. Server-roundtrip actions
            // (`med.taken` / `med.skipped`) run on the main actor
            // sequentially so the action handler does not return to the
            // system before the network call has at least started — that
            // is what keeps the runtime alive on lock-screen taps.
            // Snooze + deep-links are pure-UI and fire-and-forget.
            await dispatchAction(actionID: actionID, payload: payload)
        }

        /// Main-actor dispatch of a notification action. Public-internal
        /// scope so tests can drive the routing without the delegate
        /// dance — the test seam matches the production seam below.
        @MainActor
        func dispatchAction(actionID: String, payload: APNsPayload?) async {
            switch actionID {
            case Self.actionMedicationTaken:
                await handleMedicationTaken(payload: payload)
            case Self.actionMedicationSnooze:
                await handleMedicationSnooze(payload: payload)
            case Self.actionMedicationSkipped:
                await handleMedicationSkipped(payload: payload)
            case Self.actionBriefingOpen:
                if let url = URL(string: "healthlog://dashboard") {
                    deepLinks.handle(url)
                }
            case Self.actionMoodLogNow:
                await handleMoodLogNow()
            case Self.actionMoodSnooze:
                await handleMoodSnooze(payload: payload)
            case Self.actionMoodDismiss:
                await handleMoodDismiss(payload: payload)
            case Self.actionMeasurementDone:
                // W-B189 (#23) — "Erledigt"/complete on a preventive-care
                // reminder. Routes to the measurement capture deep-link (see
                // `NotificationService+MeasurementReminder.swift`); there is no
                // confirmed server completion route in the v1.17.1 contract.
                await handleMeasurementDone(payload: payload)
            default:
                // Body-tap or unknown action — fall back to the deep-link
                // contract. If the payload carries `medicationId` we
                // route straight to the detail screen, otherwise honour
                // the `deepLink` string. v0.5.4.3 HP5: a MOOD_REMINDER
                // body-tap (default-action) routes to the mood quick-
                // entry sheet via the router. Unknown actions never crash.
                if payload?.eventType == Self.categoryMood {
                    deepLinks.routeToMoodQuickEntry()
                } else if payload?.eventType == Self.categoryMeasurementReminder {
                    // W-B189 (#23) — a preventive-care reminder body-tap deep-
                    // links to the measurement capture surface via the server-
                    // supplied `deepLink`; falls back to the dashboard when the
                    // push carries none. Shared with the "Erledigt" action so
                    // the routing stays single-source.
                    handleMeasurementBodyTap(payload: payload)
                } else if let medicationId = Self.validatedMedicationId(payload?.medicationId),
                          let url = URL(string: "healthlog://medications/\(medicationId)")
                {
                    // v0.7.0 W-SEC-M-2 — the URL parser already
                    // re-validates via `DeepLinkRoute.idAllowlist`, but
                    // the synthesised URL never benefits from defence-
                    // in-depth: a tampered `medicationId` here would
                    // construct a URL that's then re-parsed, and the
                    // fallback path would `.unknown(...)` to dashboard.
                    // Validating up-front avoids the wasted hop and
                    // keeps log lines truthful ("ID rejected" vs.
                    // "route became unknown").
                    deepLinks.handle(url)
                } else if let url = payload?.deepLink {
                    deepLinks.handle(url)
                }
            }
        }

        @MainActor
        private func handleMedicationTaken(payload: APNsPayload?) async {
            guard let payload, let rawId = payload.medicationId else {
                // Missing metadata — surface as a deep-link instead of
                // a half-formed POST. Operator-side fix: server has to
                // attach `medicationId` to the push.
                // v0.12 W0-2 — `healthlog://medications` now resolves to the
                // Meds list root (`.medications`), not `.unknown` → Dashboard.
                HLLog.notifications.error("med.taken without medicationId — falling back to Meds list")
                if let url = URL(string: "healthlog://medications") {
                    deepLinks.handle(url)
                }
                return
            }
            // v0.7.0 W-SEC-M-2 — APN-payload IDs go through the same
            // allowlist regex as deep-link IDs. A tampered / over-long /
            // non-allowlisted ID never reaches the repository POST.
            guard let medicationId = Self.validatedMedicationId(rawId) else {
                // v0.12 W0-2 — Meds list root, not Dashboard (see above).
                HLLog.notifications.error(
                    "med.taken: medicationId rejected by allowlist — falling back to Meds list"
                )
                if let url = URL(string: "healthlog://medications") {
                    deepLinks.handle(url)
                }
                return
            }
            guard let repo = medicationsRepo else {
                HLLog.notifications.error("med.taken: MedicationsRepository not wired — skipping roundtrip")
                return
            }
            let scheduledFor = payload.scheduledFor ?? .now
            do {
                // M2 — a reminder fires at the slot time but the user can tap
                // "Genommen" hours later (lock screen next morning). Record the
                // administration instant clamped to `min(scheduledFor, now)` —
                // the same canonical clamp the in-app retro path uses — so a
                // far-future-of-slot `takenAt` can't mis-band on-time/late
                // compliance.
                try await repo.recordFromReminder(
                    medicationId: medicationId,
                    scheduledFor: scheduledFor,
                    status: .taken,
                    takenAt: min(scheduledFor, .now)
                )
                HLLog.notifications.info("med.taken: server roundtrip OK medicationId=\(medicationId, privacy: .private)")
                // v0.6.0.7 Spezi Phase E — mirror the completion to the
                // SpeziScheduler `Outcome` store so the next reconcile
                // / BGAppRefresh pass does NOT re-queue a banner for
                // the same dose. Fire-and-forget — local mirror is
                // non-authoritative.
                Self.completeSpeziEventIfAvailable(
                    medicationId: medicationId,
                    scheduledFor: scheduledFor
                )
            } catch let err as HLError {
                // Med-intake triage logs must be accurate: a transient-refresh
                // 401 is durably enqueued (`shouldPersistToOutbox`), NOT a
                // non-retriable drop — log it as queued, not as a hard failure.
                if err.shouldPersistToOutbox {
                    HLLog.notifications.info(
                        "med.taken: queued on outbox medicationId=\(medicationId, privacy: .private)"
                    )
                } else {
                    HLLog.notifications.error(
                        "med.taken: non-retriable err=\(LogSanitizer.redact(String(describing: err)), privacy: .public)"
                    )
                }
            } catch {
                HLLog.notifications.error(
                    "med.taken: unexpected err=\(LogSanitizer.redact(String(describing: error)), privacy: .public)"
                )
            }
        }

        @MainActor
        private func handleMedicationSkipped(payload: APNsPayload?) async {
            guard let payload, let rawId = payload.medicationId else {
                // v0.12 W0-2 — Meds list root, not Dashboard.
                HLLog.notifications.error("med.skipped without medicationId — falling back to Meds list")
                if let url = URL(string: "healthlog://medications") {
                    deepLinks.handle(url)
                }
                return
            }
            // v0.7.0 W-SEC-M-2 — see `handleMedicationTaken` for rationale.
            guard let medicationId = Self.validatedMedicationId(rawId) else {
                // v0.12 W0-2 — Meds list root, not Dashboard.
                HLLog.notifications.error(
                    "med.skipped: medicationId rejected by allowlist — falling back to Meds list"
                )
                if let url = URL(string: "healthlog://medications") {
                    deepLinks.handle(url)
                }
                return
            }
            guard let repo = medicationsRepo else {
                HLLog.notifications.error("med.skipped: MedicationsRepository not wired — skipping roundtrip")
                return
            }
            let scheduledFor = payload.scheduledFor ?? .now
            do {
                try await repo.recordFromReminder(
                    medicationId: medicationId,
                    scheduledFor: scheduledFor,
                    status: .skipped
                )
                HLLog.notifications.info("med.skipped: server roundtrip OK medicationId=\(medicationId, privacy: .private)")
                // v0.6.0.7 Spezi Phase E — mark the matching Spezi
                // event(s) complete so the local mirror tracks the
                // skip the same way `.taken` does. SpeziScheduler does
                // not differentiate "completed = taken" from "completed
                // = skipped" at the Outcome layer; the user-facing
                // status lives on the server. The local mirror only
                // suppresses re-banner.
                Self.completeSpeziEventIfAvailable(
                    medicationId: medicationId,
                    scheduledFor: scheduledFor
                )
            } catch let err as HLError {
                // Accurate triage: a transient-refresh 401 is durably enqueued
                // (`shouldPersistToOutbox`), not a non-retriable drop.
                if err.shouldPersistToOutbox {
                    HLLog.notifications.info(
                        "med.skipped: queued on outbox medicationId=\(medicationId, privacy: .private)"
                    )
                } else {
                    HLLog.notifications.error(
                        "med.skipped: non-retriable err=\(LogSanitizer.redact(String(describing: err)), privacy: .public)"
                    )
                }
            } catch {
                HLLog.notifications.error(
                    "med.skipped: unexpected err=\(LogSanitizer.redact(String(describing: error)), privacy: .public)"
                )
            }
        }

        /// v0.6.0.7 Spezi Phase E — bridge to the SpeziScheduler
        /// `Event.complete()` call without leaking the SpeziScheduler
        /// import into `NotificationService.swift`. The bridge lives
        /// in `AppContainer+MedicationsScheduler.swift` behind a
        /// `canImport(SpeziScheduler)` gate; this static call is a
        /// no-op when the umbrella is not linked into the build (tests
        /// + macOS).
        static func completeSpeziEventIfAvailable(
            medicationId: String,
            scheduledFor: Date
        ) {
            #if canImport(SpeziScheduler)
                AppContainer.completeSpeziEventForMedication(
                    medicationId: medicationId,
                    scheduledFor: scheduledFor
                )
            #endif
        }

        @MainActor
        private func handleMedicationSnooze(payload: APNsPayload?) async {
            // Local re-schedule only. Server push state stays unchanged
            // because snooze is a client-side concept: server doesn't
            // know it should suppress the next scheduled push at the
            // 15-minute mark. The local UNTimeIntervalNotificationTrigger
            // delivers a private banner with the same metadata so the
            // user can still hit "Genommen" / "Übersprungen" on the
            // snoozed alert. Reuses the same category so the 3-action
            // chrome carries through.
            //
            // v0.7.0 W-SEC-M-2 — sanitise `medicationId` *before* it
            // becomes part of the snoozed request's `userInfo` (where
            // the next tap re-enters `handleMedicationTaken/Skipped` and
            // would re-run the allowlist anyway) and *before* it
            // becomes part of the request identifier (where an
            // unbounded payload could pollute the pending-requests
            // namespace). `buildMedicationSnoozeRequest` consumes the
            // sanitised payload directly.
            let sanitisedPayload = Self.sanitisedForSnooze(payload: payload)
            // W-B188 — the snoozed re-schedule re-shows the banner 15 min
            // later; honour the same lock-screen-privacy opt-out so the drug
            // name doesn't re-leak on the snoozed banner.
            let req = Self.buildMedicationSnoozeRequest(
                payload: sanitisedPayload,
                hideMedicationName: LockScreenPrivacy.hideMedicationName()
            )
            do {
                // Build 273 — through the shared gate (Focus filter + pending
                // budget), like every other locally scheduled reminder.
                try await addLocalNotification(req)
                HLLog.notifications.info("med.snooze.15m: re-scheduled medicationId=\(payload?.medicationId ?? "nil", privacy: .private)")
            } catch {
                HLLog.notifications.error(
                    "med.snooze.15m: scheduling failed err=\(LogSanitizer.redact(String(describing: error)), privacy: .public)"
                )
            }
        }

        /// **v0.7.0 W-SEC-M-2** — returns a copy of `payload` with
        /// `medicationId` cleared if it fails the allowlist regex.
        /// Other fields pass through untouched. Snooze-builder consumes
        /// the sanitised value so a bogus ID can never enter the
        /// rescheduled notification's `userInfo` (where the next tap
        /// would re-enter the handlers) nor the request identifier
        /// (which is a string that gets pinned into UN-internal state).
        static func sanitisedForSnooze(payload: APNsPayload?) -> APNsPayload? {
            guard let payload else { return nil }
            let cleanId = validatedMedicationId(payload.medicationId)
            return APNsPayload(
                title: payload.title,
                body: payload.body,
                eventType: payload.eventType,
                metricType: payload.metricType,
                deepLink: payload.deepLink,
                isContentAvailable: payload.isContentAvailable,
                medicationId: cleanId,
                scheduleId: payload.scheduleId,
                scheduledFor: payload.scheduledFor
            )
        }

        /// Pure builder for the medication-snooze request. Exposed at
        /// internal scope so tests can assert on the produced content +
        /// trigger shape without depending on
        /// `UNUserNotificationCenter.pendingNotificationRequests` (which
        /// is flaky in the host-app-less test runner — the simulator
        /// may not have authorization granted, so `add(_:)` can race
        /// with the lookup). Mirrors the mood-snooze builder in
        /// `NotificationService+MoodActions.swift`.
        static func buildMedicationSnoozeRequest(
            payload: APNsPayload?,
            hideMedicationName: Bool = false
        ) -> UNNotificationRequest {
            let id = "snooze-\(payload?.medicationId ?? "anon")-\(UUID().uuidString)"
            let content = UNMutableNotificationContent()
            // W-B188 — when the lock-screen-privacy opt-out is on, the server
            // payload title (the drug name) + body (the dose) are replaced by
            // a generic localized label so the snoozed banner doesn't re-leak
            // the medication name. `userInfo` below still carries the
            // medicationId so the 3 intake actions keep working.
            if hideMedicationName {
                content.title = String(localized: "Medication reminder")
                content.body = ""
            } else {
                content.title = payload?.title ?? String(localized: "Medication")
                content.body = payload?.body ?? String(localized: "Reminder")
            }
            content.sound = .default
            content.categoryIdentifier = Self.categoryMedication
            // Snoozed banner must inherit the same time-sensitive priority
            // as the original medication push — otherwise iOS demotes the
            // rescheduled banner to `.active` and the user learns "snoozing
            // = priority lost". Mirrors the rewrite in `HealthLogStandard.
            // notificationContent(for:content:)` for the initial banner.
            content.interruptionLevel = .timeSensitive
            // Preserve the metadata so the snoozed banner's actions still
            // have a medicationId + scheduledFor to act on. Without this
            // the snoozed push would render the 3 buttons but the handler
            // would fall through to the deep-link path.
            var userInfo: [String: Any] = [:]
            if let payload {
                if let id = payload.medicationId { userInfo["medicationId"] = id }
                if let sid = payload.scheduleId { userInfo["scheduleId"] = sid }
                if let date = payload.scheduledFor {
                    userInfo["scheduledFor"] = Self.iso8601String(from: date)
                }
                if let eventType = payload.eventType { userInfo["eventType"] = eventType }
            }
            content.userInfo = userInfo

            let trigger = UNTimeIntervalNotificationTrigger(
                timeInterval: Self.snoozeIntervalSeconds,
                repeats: false
            )
            return UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        }

        /// Helper — emits the ISO-8601 representation the server
        /// originally sent, so the snoozed banner's `userInfo` keeps the
        /// same shape (the action handler re-parses via `APNsPayload`).
        ///
        /// Internal (was `private`) so the local-fallback orchestrator
        /// (W-MED) builds the same userInfo shape without re-implementing
        /// the formatter — single-source guarantee.
        static func iso8601String(from date: Date) -> String {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f.string(from: date)
        }

        /// Canonical `userInfo` shape for a medication-reminder banner —
        /// mirrors the server APNs payload contract so the on-tap action
        /// handler (`dispatchAction`) drives `med.taken` / `med.skipped` /
        /// `med.snooze.15m` regardless of whether the banner originated
        /// from the server cron, the local fallback, or the smart-reminder
        /// wrapper.
        /// Parse a banner's userInfo into the action payload, resolving
        /// `scheduledFor` for Spezi-built medication banners.
        ///
        /// SpeziScheduler materialises its `UNNotificationRequest`s at reconcile
        /// time and the `SchedulerNotificationsConstraint` hook only sees task +
        /// content, never the trigger — so the `scheduledFor` stamped there
        /// (`HealthLogStandard.notificationContent(for:content:)`) is the BUILD
        /// instant, not the fire instant. Acting on it would post "taken" against
        /// yesterday's reconcile time and miss today's slot. Those banners carry
        /// `speziScheduled: true`; for them the delivery date IS the slot (Spezi
        /// fires at the occurrence start), so we substitute it. Server pushes
        /// carry the real slot and are left untouched.
        nonisolated static func resolvedPayload(
            userInfo: [AnyHashable: Any],
            deliveredAt: Date
        ) -> APNsPayload? {
            guard let parsed = APNsPayload.parse(userInfo: userInfo) else { return nil }
            guard userInfo["speziScheduled"] as? Bool == true else { return parsed }
            return APNsPayload(
                title: parsed.title,
                body: parsed.body,
                eventType: parsed.eventType,
                metricType: parsed.metricType,
                deepLink: parsed.deepLink,
                isContentAvailable: parsed.isContentAvailable,
                medicationId: parsed.medicationId,
                scheduleId: parsed.scheduleId,
                scheduledFor: deliveredAt,
                reminderId: parsed.reminderId
            )
        }

        static func medicationUserInfo(
            medicationId: String,
            scheduleId: String?,
            scheduledFor: Date
        ) -> [String: Any] {
            var info: [String: Any] = [
                "medicationId": medicationId,
                "scheduledFor": iso8601String(from: scheduledFor),
                "eventType": categoryMedication
            ]
            if let scheduleId {
                info["scheduleId"] = scheduleId
            }
            return info
        }
    }

#endif
