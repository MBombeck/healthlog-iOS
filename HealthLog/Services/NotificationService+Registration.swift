import CryptoKit
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
        /// a token change without re-implementing the dedup loop.
        func register(tokenHex: String, env: APNsEnvironment, forceFresh: Bool) async {
            // Capture the current LA push token into the dedup
            // key so a *new* token re-fires the POST while an unchanged one
            // short-circuits. Read once here so the value POSTed matches the
            // value compared (no TOCTOU between the dedup check and the body).
            let (next, pushFields) = registrationAttempt(tokenHex: tokenHex, env: env)
            let attemptAt = registrationClock()
            if !forceFresh, isAlreadySent(next, now: attemptAt) {
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
                try await postDevice(next, pushFields: pushFields)
                remember(next, at: attemptAt)
                HLLog.notifications.info("APNs-Token registriert env=\(env.rawValue) tokenLen=\(tokenHex.count)")
                persistSnapshot(
                    tokenHex: tokenHex,
                    env: env,
                    attemptAt: attemptAt,
                    serverStatus: 200,
                    errorMessage: nil
                )
            } catch let HLError.server(status, _, msg) where status == 409 {
                relayRegistrationFailed?()
                HLLog.notifications
                    .warning(
                        "APNs-Token 409 — anderem User zugeordnet, recovery via Server-Feedback. msg=\(LogSanitizer.redact(msg), privacy: .public)"
                    )
                // D3 #2: not remembered as sent. This account has no push
                // registration yet, so the next launch or token callback tries
                // again instead of waiting a day.
                persistSnapshot(
                    tokenHex: tokenHex,
                    env: env,
                    attemptAt: attemptAt,
                    serverStatus: 409,
                    errorMessage: LogSanitizer.redact(msg)
                )
            } catch let HLError.server(status, code, msg) {
                if status == 422, let code, code.hasPrefix("devices.push.") { await relayRegistrationRejected?(code) }
                relayRegistrationFailed?()
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
                relayRegistrationFailed?()
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

        /// Whether this account's registration reached the server within the day.
        private func isAlreadySent(_ state: RegistrationState, now: Date) -> Bool {
            Self.registrationIsCurrent(state, owner: registrationOwner, sent: Self.loadSentRegistration(from: defaults), now: now)
        }

        /// The registration the server now has, and when it got it. Kept on
        /// disk, so a relaunch within the day does not post it again.
        private func remember(_ state: RegistrationState, at sentAt: Date) {
            lastRegistration = state
            let sent = SentRegistration(fingerprint: Self.fingerprint(state, owner: registrationOwner), sentAt: sentAt)
            if let data = try? JSONEncoder().encode(sent) {
                defaults.set(data, forKey: Self.sentRegistrationDefaultsKey)
            }
        }

        /// How long an unchanged registration counts as sent. A foreground
        /// after that re-posts it once, which keeps `Device.lastSeen` fresh.
        static let registrationRefreshInterval: TimeInterval = 24 * 60 * 60

        /// What last reached the server: a fingerprint of account and
        /// registration (never the token itself) and when it was sent.
        struct SentRegistration: Codable, Equatable {
            let fingerprint: String
            let sentAt: Date
        }

        /// Its own key, apart from the diagnostics snapshot, which also
        /// records failed attempts.
        static let sentRegistrationDefaultsKey = "dev.healthlog.app.notif.sentRegistration.v1"

        static func loadSentRegistration(from defaults: UserDefaults) -> SentRegistration? {
            guard let data = defaults.data(forKey: sentRegistrationDefaultsKey) else { return nil }
            return try? JSONDecoder().decode(SentRegistration.self, from: data)
        }

        /// SHA-256 over account, token, environment and Live-Activity token.
        static func fingerprint(_ state: RegistrationState, owner: String) -> String {
            // The per-Activity list only when sent (an empty list too, which
            // clears the server's): without it a registration keeps the
            // fingerprint it had before 1.7, so an update does not re-post.
            var parts = [owner, state.tokenHex, state.env.rawValue, state.liveActivityPushToken ?? ""]
            if let list = state.liveActivityTokens {
                parts.append("la:" + list.map { "\($0.medicationId)@\(Int($0.slotInstant.timeIntervalSince1970))=\($0.token)" }
                    .joined(separator: ","))
            }
            // The device's own fields (#179, #190) likewise only when there
            // are any.
            if !state.pushFingerprint.isEmpty { parts.append(state.pushFingerprint) }
            let digest = SHA256.hash(data: Data(parts.joined(separator: "|").utf8))
            return digest.map { String(format: "%02x", $0) }.joined()
        }

        /// Whether `next` for `owner` was already sent and is younger than a day.
        static func registrationIsCurrent(
            _ next: RegistrationState,
            owner: String,
            sent: SentRegistration?,
            now: Date
        ) -> Bool {
            guard let sent, sent.fingerprint == fingerprint(next, owner: owner) else { return false }
            let age = now.timeIntervalSince(sent.sentAt)
            return age >= 0 && age < registrationRefreshInterval
        }

        /// The dedup key and the body additions of one attempt. The Live
        /// Activity token is read once, so the value posted matches the value
        /// compared; the relay provider is asked once, so a binding counter
        /// moves once per attempt.
        func registrationAttempt(tokenHex: String, env: APNsEnvironment) -> (RegistrationState, DeviceRegistrationPushFields) {
            let liveActivityPushToken = currentLiveActivityPushToken
            // #190 5.4: with the relay on, each entry carries its signed
            // activity statement; the relay sees it only inside the `end`.
            let liveActivityTokens = currentLiveActivityTokens?.map { entry in
                var signed = entry
                signed.relayProof = relayActivityProof?(entry.token)
                return signed
            }
            let pushFields = currentPushFields(tokenHex: tokenHex)
            let state = RegistrationState(
                tokenHex: tokenHex,
                env: env,
                liveActivityPushToken: liveActivityPushToken,
                liveActivityTokens: liveActivityTokens,
                pushFingerprint: pushFields.fingerprint
            )
            return (state, pushFields)
        }

        func postDevice(_ state: RegistrationState, pushFields: DeviceRegistrationPushFields) async throws {
            try await postDevice(
                tokenHex: state.tokenHex,
                env: state.env,
                liveActivityPushToken: state.liveActivityPushToken,
                liveActivityTokens: state.liveActivityTokens,
                pushFields: pushFields
            )
        }

        /// The fields this device adds on its own behalf (#179, #190).
        func currentPushFields(tokenHex: String) -> DeviceRegistrationPushFields {
            var fields = relayRegistrationProvider?(tokenHex) ?? DeviceRegistrationPushFields()
            fields.medicationDelivery = medicationDeliveryReport
            return fields
        }

        /// #179 — the device's delivery changed: post it once with the cached
        /// token (the dedup drops an unchanged value).
        func noteMedicationDelivery(_ report: DeviceMedicationDeliveryReport) async {
            guard medicationDeliveryReport != report else { return }
            medicationDeliveryReport = report
            await reRegisterWithCachedToken()
        }

        /// Re-posts with the token the OS delivered this launch; a no-op
        /// before it did.
        func reRegisterWithCachedToken() async {
            guard let snapshot = lastRegistrationSnapshot,
                  let tokenHex = snapshot.fullTokenHex,
                  let env = APNsEnvironment(rawValue: snapshot.environment ?? "") else { return }
            await register(tokenHex: tokenHex, env: env, forceFresh: false)
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
            var eventType = payload?.eventType
            // #190 5.3: with the relay on, only an opened envelope counts; its
            // template replaces anything the plaintext payload claims.
            switch await relaySilentGate?(userInfo.raw) ?? .notInEnvelopeMode {
            case .notInEnvelopeMode:
                break
            case .handled:
                return .noData
            case .refused:
                HLLog.notifications.notice("Silent push without a valid envelope: no sync")
                return .noData
            case let .opened(template):
                eventType = template
            }
            // 1.7: a plaintext confirmation delivered silently resolves its
            // dose in the ledger the widget and the next start read (the relay
            // records its opened envelope itself).
            if MedicationIntakeRecordedGate.isOpen(), let dose = MedicationIntakeRecordedPush.parse(userInfo: userInfo.raw) {
                ResolvedDoseLedger().record(dose)
            }
            HLLog.notifications.info("Silent push empfangen — eventType=\(eventType ?? "nil")")
            // #66 P0.1 (Baustein 4) — honest evidence: a silent-push wake fired.
            HKSyncDiagnostics.shared.recordWake(.push)
            // iOS ends the wake after about 30 s; answering late costs future
            // pushes. The pass learns when its time is up and holds its cursors.
            let resolvedEventType = eventType
            return await SilentPushWakeBudget.run(limit: silentPushBudget, fallback: .failed) { [self] isExpired in
                await runSilentPushWork(eventType: resolvedEventType, isExpired: isExpired)
            }
        }

        private func runSilentPushWork(
            eventType: String?,
            isExpired: @escaping @Sendable () -> Bool
        ) async -> UIBackgroundFetchResult {
            // #66 P0.1 (Baustein 3) — the silent push is a THIRD HK wake channel
            // (alongside BGProcessing + BGAppRefresh). Every server wake runs one
            // incremental pass, so HK data + queued user writes reach the server
            // without waiting for a foreground.
            //
            // One named trigger, one pass. This used
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
            // R5 — every silent push extends the local medication reminders
            // from the cached list (no request), not only the intake-sync push
            // below. A push is a wake the app gets without being opened.
            //
            // #188 (3): a server intake push (eventType MEDICATION_INTAKE_SYNC,
            // sent to the user's other devices when a dose is marked taken on
            // the web/another device) reconciles the medications store FIRST and
            // awaits the Live Activity end and the reminder completion it
            // drives. It used to run after the reminder top-up and the whole
            // HealthKit pass, inside the same ~30 s wake, and its Live Activity
            // end was a task nobody awaited. HealthKit follows only while the
            // wake has time left. The push is a shortcut; the foreground reload
            // stays the path that does not depend on it.
            // #191: new readings on the server. The stores, widgets and the
            // Watch reload (coalesced); no HealthKit pass, nothing went up.
            if eventType == RelayDataChange.template {
                let reloaded = await relayDataChanged?() ?? false
                // R1 (11): like every other silent push, this wake extends
                // the local medication reminders (cached list, no request).
                await backgroundSync?.runReminderTopUp()
                return reloaded ? .newData : .noData
            }
            // 1.7: a confirmation delivered silently reconciles like the
            // intake sync (its dose went to the ledger on receipt).
            let isIntakeSync = eventType == RelayTemplate.intakeSync || eventType == RelayTemplate.intakeRecorded
            var didReconcile = false
            if isIntakeSync {
                didReconcile = await backgroundSync?.runMedicationIntakeSync() ?? false
            }
            await backgroundSync?.runReminderTopUp()
            guard !(isIntakeSync && isExpired()) else {
                return didReconcile ? .newData : .noData
            }
            let answered = await backgroundSync?
                .runHealthSyncPass(HealthSyncTrigger.silentPush, isExpired: isExpired) ?? []
            let didSync = !answered.isEmpty
            return (didReconcile || didSync) ? .newData : .noData
        }

        // MARK: - Local fallback reminder

        /// Schedules a local notification at a wall-clock date.
        ///
        /// **W-MED fix:** previously omitted `category` + `userInfo`
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
            // Route through the gate so a HealthLog Focus filter
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
        /// Previously this built a
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
            // Hide content in notifications: only the neutral text is stored.
            NotificationContentPrivacy.apply(
                to: content,
                kind: NotificationContentPrivacy.kind(category: category, eventType: userInfo["eventType"] as? String)
            )

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

        // MARK: - lastRegistrationSnapshot persistence

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
