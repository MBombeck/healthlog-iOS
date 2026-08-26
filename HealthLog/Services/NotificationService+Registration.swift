import Foundation
#if canImport(UserNotifications)
    import UserNotifications
#endif
#if canImport(UIKit)
    import UIKit
#endif

#if canImport(UserNotifications) && canImport(UIKit)

    /// APNs registration bridge (`AppDelegateBridge`: didRegister / forceRefresh
    /// / didFail / didReceiveSilentNotification) + local fallback reminder +
    /// `LastRegistrationSnapshot` persistence. Split out of
    /// `NotificationService.swift` (file_length discipline — pure move, no
    /// behaviour change).
    @MainActor
    extension NotificationService {
        // MARK: - AppDelegateBridge

        func didRegister(deviceToken: Data) async {
            let hex = deviceToken.hexEncodedString()
            let env: APNsEnvironment = {
                #if DEBUG
                    return .sandbox
                #else
                    return .production
                #endif
            }()
            await register(tokenHex: hex, env: env, forceFresh: false)
        }

        /// Re-issues `POST /api/devices` with the cached APNs token,
        /// bypassing the `(tokenHex, env)` dedup. Operator-facing debug
        /// affordance exposed in `NotificationDiagnosticsScreen` — surfaces
        /// stale-token failures on demand when a push silently dropped
        /// server-side. Returns `nil` when no token has ever been cached
        /// (the OS never delivered one — the caller should re-trigger the
        /// authorization flow first).
        @discardableResult
        func forceRefreshRegistration() async -> LastRegistrationSnapshot? {
            guard let snapshot = lastRegistrationSnapshot, snapshot.hasToken else {
                HLLog.notifications.warning("Force-fresh registration requested but no cached token.")
                return nil
            }
            guard let tokenHex = snapshot.fullTokenHex,
                  let env = APNsEnvironment(rawValue: snapshot.environment ?? "") else
            {
                HLLog.notifications.warning("Force-fresh registration cache incomplete — bailing.")
                return nil
            }
            await register(tokenHex: tokenHex, env: env, forceFresh: true)
            return lastRegistrationSnapshot
        }

        /// Core registration loop. Captures the result into
        /// `lastRegistrationSnapshot` regardless of outcome so the
        /// diagnostics surface always reflects the most recent attempt.
        /// Internal (not `private`) so the Live-Activity token sink in
        /// `NotificationService+LiveActivity.swift` can re-issue registration on
        /// a token change (W-B189 #22) without re-implementing the dedup loop.
        func register(tokenHex: String, env: APNsEnvironment, forceFresh: Bool) async {
            // W-B189 (#22) — capture the current LA push token into the dedup
            // key so a *new* token re-fires the POST while an unchanged one
            // short-circuits. Read once here so the value POSTed matches the
            // value compared (no TOCTOU between the dedup check and the body).
            let liveActivityPushToken = currentLiveActivityPushToken
            let next = RegistrationState(
                tokenHex: tokenHex,
                env: env,
                liveActivityPushToken: liveActivityPushToken
            )
            let attemptAt = Date.now
            if !forceFresh, next == lastRegistration {
                HLLog.notifications.debug("APNs-Token unverändert — kein POST.")
                // Refresh the attempt timestamp so the operator can see
                // the registration loop ran even when the dedup short-
                // circuited the network call.
                updateSnapshot { snapshot in
                    snapshot.lastRegistrationAttemptAt = attemptAt
                }
                return
            }
            do {
                try await postDevice(
                    tokenHex: tokenHex,
                    env: env,
                    liveActivityPushToken: liveActivityPushToken
                )
                lastRegistration = next
                HLLog.notifications.info("APNs-Token registriert env=\(env.rawValue) tokenLen=\(tokenHex.count)")
                persistSnapshot(
                    tokenHex: tokenHex,
                    env: env,
                    attemptAt: attemptAt,
                    serverStatus: 200,
                    errorMessage: nil
                )
            } catch let HLError.server(status, _, msg) where status == 409 {
                HLLog.notifications
                    .warning(
                        "APNs-Token 409 — anderem User zugeordnet, recovery via Server-Feedback. msg=\(LogSanitizer.redact(msg), privacy: .public)"
                    )
                lastRegistration = next
                persistSnapshot(
                    tokenHex: tokenHex,
                    env: env,
                    attemptAt: attemptAt,
                    serverStatus: 409,
                    errorMessage: LogSanitizer.redact(msg)
                )
            } catch let HLError.server(status, _, msg) {
                HLLog.notifications
                    .error("APNs-Registrierung server-error status=\(status) msg=\(LogSanitizer.redact(msg), privacy: .public)")
                persistSnapshot(
                    tokenHex: tokenHex,
                    env: env,
                    attemptAt: attemptAt,
                    serverStatus: status,
                    errorMessage: LogSanitizer.redact(msg)
                )
            } catch {
                HLLog.notifications.error("APNs-Registrierung fehlgeschlagen: \(error.localizedDescription)")
                persistSnapshot(
                    tokenHex: tokenHex,
                    env: env,
                    attemptAt: attemptAt,
                    serverStatus: nil,
                    errorMessage: LogSanitizer.redact(String(describing: error))
                )
            }
        }

        func didFailToRegister(error: any Error) async {
            HLLog.notifications.error("registerForRemoteNotifications failed: \(error.localizedDescription)")
            // Capture the OS-side failure too so the operator can see
            // "Apple never delivered a token" in the diagnostics surface.
            let attemptAt = Date.now
            let sanitized = LogSanitizer.redact(String(describing: error))
            updateSnapshot { snapshot in
                snapshot.lastRegistrationAttemptAt = attemptAt
                snapshot.lastRegistrationServerStatus = nil
                snapshot.lastRegistrationError = sanitized
            }
        }

        func didReceiveSilentNotification(userInfo: RemoteNotificationUserInfo) async -> UIBackgroundFetchResult {
            let payload = APNsPayload.parse(userInfo: userInfo.raw)
            HLLog.notifications.info("Silent push empfangen — eventType=\(payload?.eventType ?? "nil")")
            // #66 P0.1 (Baustein 4) — honest evidence: a silent-push wake fired.
            HKSyncDiagnostics.shared.recordWake(.push)
            // #66 P0.1 (Baustein 3) — the silent push is a THIRD HK wake channel
            // (alongside BGProcessing + BGAppRefresh). Every server wake runs one
            // incremental pass, so HK data + queued user writes reach the server
            // without waiting for a foreground.
            //
            // **Phase 07 / plan 07-09** — one named trigger, one pass. This used
            // to be three calls: a `.push` collection trigger (which already ran
            // the orchestrated `silentPush` pass), then the workout pass, then
            // the outbox drain — the last two of which that pass also contains.
            // `HealthSyncTrigger.silentPush` plans the incremental set under the
            // short-wake budget (one page per type, incremental only, no first
            // history walk), and the capabilities outside it come back `deferred`
            // rather than silently missing.
            //
            // CU-21 (1) — alles, was dieser Push anstößt, trägt auf dem Draht
            // `syncTrigger: "push"`. Das ist der dritte Auslöser, mit dem der
            // Server „liefert selbstständig" belegen kann. Explizites
            // `begin`/`defer end` statt ``SyncTriggerContext/withTrigger(_:_:)``,
            // weil dieser Pfad `@MainActor`-isoliert ist und die Closure sonst
            // über die Isolationsgrenze gereicht werden müsste.
            SyncTriggerContext.shared.begin(.push)
            defer { SyncTriggerContext.shared.end(.push) }
            let answered = await backgroundSync?
                .runHealthSyncPass(HealthSyncTrigger.silentPush) ?? []
            let didSync = !answered.isEmpty
            // b182 W-B182 (#22): a server intake push (eventType
            // MEDICATION_INTAKE_SYNC, sent to the user's other devices when a
            // dose is marked taken on the web/another device) reconciles the
            // medications store immediately — ends the remotely-taken dose's
            // Live Activity + reloads widgets + refreshes state without waiting
            // for the next foreground or BGProcessingTask wake. Server side
            // tracked in GH #22; until it ships no such push arrives and this
            // stays a no-op. Deliberately outside the pass: reconciling a store
            // is not a HealthKit capability.
            if payload?.eventType == "MEDICATION_INTAKE_SYNC" {
                let didReconcile = await backgroundSync?.runMedicationReconcile() ?? false
                return (didReconcile || didSync) ? .newData : .noData
            }
            return didSync ? .newData : .noData
        }

        // MARK: - Local fallback reminder

        /// Schedules a local notification at a wall-clock date.
        ///
        /// **W-MED fix (v0.5.5):** previously omitted `category` + `userInfo`
        /// parameters so a medication-reminder banner scheduled via the
        /// smart-reminder wrapper rendered without the 3-button chrome.
        /// Both fields are now first-class with backwards-compatible
        /// defaults; medication callers pass `category:
        /// Self.categoryMedication` + `Self.medicationUserInfo(...)`.
        func scheduleLocalReminder(
            id: String,
            title: String,
            body: String,
            at date: Date,
            category: String? = nil,
            userInfo: [String: Any] = [:]
        ) async throws {
            let req = Self.buildLocalReminderRequest(
                id: id,
                title: title,
                body: body,
                at: date,
                category: category,
                userInfo: userInfo
            )
            // W-FOCUS-FILTER — route through the gate so a HealthLog Focus filter
            // can hold this back when it is a routine reminder. Urgent levels
            // (.timeSensitive/.critical) always pass; the schedule is untouched.
            try await addLocalNotification(req)
        }

        /// Pure request builder for `scheduleLocalReminder`. Exposed at
        /// internal scope so tests can pin the trigger contract without
        /// depending on `UNUserNotificationCenter` authorization — the
        /// `add(...)` call in the test runner silently drops the request
        /// when no permission is granted, which masks the trigger shape.
        ///
        /// v0.5.5 NOTIF-FIX: previously this built a
        /// `UNCalendarNotificationTrigger` keyed on minute precision
        /// (`[.year, .month, .day, .hour, .minute]`) with
        /// `repeats: false`. iOS treats such a trigger as "fire at the
        /// FIRST instant the components match" — if the target minute
        /// has already begun (e.g. scheduling at xx:42:30 for xx:42:45)
        /// the trigger never fires for the rest of that minute, and
        /// with `repeats: false` it never fires at all. Symptom:
        /// operator reports "even the local reminders I trigger don't
        /// arrive". The fix: when the target lies within the next
        /// ~5 minutes, use a precise time-interval trigger; otherwise
        /// build the calendar trigger with second-granularity so the
        /// matching window is unambiguous.
        ///
        /// v0.7.1 QoL-3-H-2 (TZ contract): the calendar branch now stamps
        /// an explicit `timeZone` on the matched `DateComponents`. Without
        /// it, `UNCalendarNotificationTrigger` interprets the components in
        /// whatever timezone the device happens to be in *at fire time* —
        /// so a reminder built at 09:00 in Berlin would fire at 09:00 in
        /// New York (= a four-to-nine-hour drift) after the traveller's
        /// device crosses zones. We pin the timezone captured **at
        /// scheduling time** (`calendar.timeZone`, default
        /// `Calendar.current`), which fixes the trigger to the exact
        /// instant the operator intended when they set the schedule — the
        /// wall-clock-in-the-scheduling-zone. This makes the projection
        /// deterministic (no implicit runtime-default dependency) and
        /// unit-testable, and matches the medication-reminder intent: the
        /// dose time the user configured, not a moving wall-clock target.
        static func buildLocalReminderRequest(
            id: String,
            title: String,
            body: String,
            at date: Date,
            category: String? = nil,
            userInfo: [String: Any] = [:],
            now: Date = .now,
            calendar: Calendar = .current
        ) -> UNNotificationRequest {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            if let category {
                content.categoryIdentifier = category
            }
            if !userInfo.isEmpty {
                content.userInfo = userInfo
            }

            let interval = date.timeIntervalSince(now)
            let trigger: UNNotificationTrigger
            if interval > 0, interval <= 300 {
                trigger = UNTimeIntervalNotificationTrigger(
                    timeInterval: max(1, interval),
                    repeats: false
                )
            } else {
                var comps = calendar.dateComponents(
                    [.year, .month, .day, .hour, .minute, .second],
                    from: date
                )
                // Pin the scheduling-time timezone so the fire instant is
                // unambiguous across timezone travel (QoL-3-H-2). Including
                // `.timeZone` in the matched components removes the implicit
                // "current device timezone at fire time" semantics.
                comps.timeZone = calendar.timeZone
                trigger = UNCalendarNotificationTrigger(
                    dateMatching: comps,
                    repeats: false
                )
            }
            return UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        }

        // MARK: - lastRegistrationSnapshot persistence (v0.6.0.8)

        /// Updates the in-memory snapshot in place and mirrors the result
        /// to UserDefaults. The mutation closure receives a writable
        /// `LastRegistrationSnapshot` so the caller can edit individual
        /// fields without re-supplying every value.
        private func updateSnapshot(_ mutate: (inout LastRegistrationSnapshot) -> Void) {
            var next = lastRegistrationSnapshot ?? LastRegistrationSnapshot()
            mutate(&next)
            lastRegistrationSnapshot = next
            Self.persist(next, to: defaults)
        }

        private func persistSnapshot(
            tokenHex: String,
            env: APNsEnvironment,
            attemptAt: Date,
            serverStatus: Int?,
            errorMessage: String?
        ) {
            updateSnapshot { snapshot in
                snapshot.setToken(hex: tokenHex)
                snapshot.environment = env.rawValue
                snapshot.lastRegistrationAttemptAt = attemptAt
                snapshot.lastRegistrationServerStatus = serverStatus
                snapshot.lastRegistrationError = errorMessage
            }
        }

        static func loadLastRegistration(from defaults: UserDefaults) -> LastRegistrationSnapshot? {
            guard let data = defaults.data(forKey: lastRegistrationDefaultsKey) else { return nil }
            return try? JSONDecoder().decode(LastRegistrationSnapshot.self, from: data)
        }

        static func persist(_ snapshot: LastRegistrationSnapshot, to defaults: UserDefaults) {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            defaults.set(data, forKey: lastRegistrationDefaultsKey)
        }
    }

#endif
