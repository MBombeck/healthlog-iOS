#if canImport(ActivityKit)
    import ActivityKit
    import Foundation

    /// **v0.8.4 WWIDGET-1 — owns the medication Live Activity lifecycle.**
    ///
    /// A single `@MainActor` controller that wraps ActivityKit's
    /// `Activity.request` / `update` / `end` for the medication-reminder
    /// Live Activity. The app starts an Activity when the next dose is known
    /// (driven from `MedicationsStore` reconcile / reminder scheduling),
    /// updates the countdown + status as the dose state changes, and ends it
    /// when the dose is taken / skipped / expired.
    ///
    /// **Concurrency:** `@MainActor`-isolated because ActivityKit's
    /// `request/update/end` are main-actor-friendly and the controller is
    /// driven from `@MainActor` stores. No `@unchecked Sendable`, no
    /// `assumeIsolated` — the attributes + content state are `Sendable`
    /// value types and cross the await boundary cleanly.
    ///
    /// **Push-to-start prep:** on iOS 17.2+ the controller subscribes to
    /// `Activity.pushToStartTokenUpdates` and hands each token to the
    /// injected ``PushTokenSink`` so the existing device-registration path
    /// can forward it to the server. Per-activity update tokens
    /// (`activity.pushTokenUpdates`) are forwarded the same way once an
    /// Activity is running. The server contract is documented in
    /// `.planning/v084/WWIDGET-1-report.md`; no server work is required for
    /// the **local** lifecycle to function.
    /// **b181 W-B181 — spy-able seam for the reconcile routine.**
    ///
    /// The side-effecting surface the central reconcile
    /// (`AppContainer.reconcileMedicationLiveActivity`) drives. Abstracted
    /// behind a protocol so the reconcile decision — "a remote-taken dose must
    /// end its Live Activity, a still-due dose must (re)start it, nothing
    /// in-window must clear all" — is verifiable with a recording double,
    /// without a live ActivityKit surface (which only exists on a real device).
    /// The concrete ``MedicationLiveActivityController`` conforms; the
    /// reconcile is generic over this so production wires the real controller
    /// and the tests wire a spy.
    @MainActor
    protocol MedicationLiveActivityReconciling: AnyObject {
        /// `true` when Live Activities are user-enabled (gates every mutation).
        var areActivitiesEnabled: Bool { get }

        @discardableResult
        func start(
            medicationId: String,
            medicationName: String,
            doseText: String,
            scheduledFireDate: Date,
            isOverdue: Bool,
            now: Date
        ) async -> String?

        func end(
            medicationId: String,
            finalStatus: MedicationActivityAttributes.ContentState.Status,
            countdownTarget: Date,
            dismissalPolicy: ActivityUIDismissalPolicy
        ) async

        func endAll(dismissalPolicy: ActivityUIDismissalPolicy) async
    }

    @MainActor
    final class MedicationLiveActivityController: MedicationLiveActivityReconciling {
        /// Receives Live-Activity push tokens (push-to-start + per-activity
        /// update tokens) as lowercase hex so the device-registration path
        /// can forward them to the server. Abstracted behind a protocol so
        /// the controller stays testable without a live `NotificationService`.
        typealias PushTokenSink = LiveActivityPushTokenSink

        private let tokenSink: PushTokenSink?

        /// Tracks the in-flight token-forwarding tasks so they are
        /// cancelled on `deinit` / stop. Keyed by a stable label.
        private var tokenStreamTasks: [String: Task<Void, Never>] = [:]

        init(tokenSink: PushTokenSink? = nil) {
            self.tokenSink = tokenSink
        }

        // MARK: - Capability gate

        /// `true` when the user has Live Activities enabled for the app
        /// (Settings → HealthLog → Live Activities). Every public mutation
        /// gates on this so a disabled user is a silent no-op, not a crash.
        var areActivitiesEnabled: Bool {
            ActivityAuthorizationInfo().areActivitiesEnabled
        }

        // MARK: - Start

        /// Start (or refresh) the Live Activity for a due dose. If an
        /// Activity for the same `medicationId` is already running we
        /// **update** it in place instead of stacking a duplicate — the
        /// reconcile path can call this idempotently after every store
        /// load.
        ///
        /// Returns the running Activity's id on success, `nil` when
        /// Activities are disabled or the request failed (logged).
        @discardableResult
        func start(
            medicationId: String,
            medicationName: String,
            doseText: String,
            scheduledFireDate: Date,
            isOverdue: Bool = false,
            now _: Date = .now
        ) async -> String? {
            guard areActivitiesEnabled else {
                HLLog.notifications.debug("LiveActivity start skipped — Activities disabled.")
                return nil
            }

            // Idempotent: an Activity already exists for this med → update.
            if let existing = runningActivity(for: medicationId) {
                await update(
                    medicationId: medicationId,
                    status: .pending,
                    countdownTarget: scheduledFireDate,
                    isOverdue: isOverdue
                )
                observeUpdateToken(for: existing)
                return existing.id
            }

            // W-B188 (AUDIT-SEC-b187 High) — when the user opted in to hide
            // medication names on the lock screen, bake a GENERIC label + an
            // empty dose into the (static) attributes the widget process
            // renders verbatim. The `medicationId` is unchanged, so the
            // in-place "Genommen" intent still records the correct dose — only
            // the visible PHI on the Lock Screen / Dynamic Island / Watch
            // glance is hidden. Resolved here in the app process (the widget
            // extension can't read the app's UserDefaults), so the redacted
            // name travels in the attributes. Default OFF → real name shown.
            let hideName = LockScreenPrivacy.hideMedicationName()
            let displayName = hideName
                ? String(localized: "Medication reminder")
                : medicationName
            let displayDose = hideName ? "" : doseText
            let attributes = MedicationActivityAttributes(
                medicationId: medicationId,
                medicationName: displayName,
                doseText: displayDose,
                scheduledFireDate: scheduledFireDate,
                intakeScheduledFor: scheduledFireDate
            )
            let initialState = MedicationActivityAttributes.ContentState(
                status: .pending,
                countdownTarget: scheduledFireDate,
                isOverdue: isOverdue,
                // W-B187 — carry the user's resolved 12h/24h/auto preference (the
                // SAME source the home-screen widget snapshot writer uses) so the
                // Lock-Screen dose time renders through `HLTimeFormat`, never the
                // raw device-locale clock. The widget process can't read the app's
                // UserDefaults mirror, so the value must travel in the state.
                timeFormatRaw: HLTimeFormat.current().rawValue
            )

            do {
                let activity = try Activity.request(
                    attributes: attributes,
                    content: ActivityContent(
                        state: initialState,
                        // Auto-stale a little after the dose is due so a
                        // forgotten Activity dims rather than lingering as
                        // a live countdown forever.
                        staleDate: scheduledFireDate.addingTimeInterval(60 * 60)
                    ),
                    pushType: tokenSink == nil ? nil : .token
                )
                HLLog.notifications.info("LiveActivity started med=\(medicationId, privacy: .private)")
                observeUpdateToken(for: activity)
                return activity.id
            } catch {
                HLLog.notifications.error("LiveActivity request failed: \(error.localizedDescription)")
                return nil
            }
        }

        // MARK: - Update

        /// Update the running Activity's status + countdown target. No-op
        /// when no Activity is running for the medication.
        func update(
            medicationId: String,
            status: MedicationActivityAttributes.ContentState.Status,
            countdownTarget: Date,
            isOverdue: Bool = false
        ) async {
            guard let activity = runningActivity(for: medicationId) else { return }
            let state = MedicationActivityAttributes.ContentState(
                status: status,
                countdownTarget: countdownTarget,
                isOverdue: isOverdue,
                // W-B187 — re-resolve the current time-format preference on every
                // update so a mid-activity profile change (12h↔24h) propagates to
                // the Lock-Screen dose time.
                timeFormatRaw: HLTimeFormat.current().rawValue
            )
            // Await inline on the MainActor: the non-`Sendable` `activity`
            // never crosses a `Task` (sending) boundary, which keeps Swift 6
            // strict-concurrency happy without `@unchecked`/`assumeIsolated`.
            await activity.update(ActivityContent(state: state, staleDate: nil))
        }

        // MARK: - End

        /// End the running Activity for a medication. `finalStatus`
        /// determines the brief confirmation frame shown before dismissal
        /// (`.taken` → ✓). The dismissal policy defaults to a short delay
        /// so the user sees the confirmation, then the Activity clears.
        func end(
            medicationId: String,
            finalStatus: MedicationActivityAttributes.ContentState.Status,
            countdownTarget: Date = .now,
            dismissalPolicy: ActivityUIDismissalPolicy = .default
        ) async {
            guard let activity = runningActivity(for: medicationId) else { return }
            tokenStreamTasks.removeValue(forKey: activity.id)?.cancel()
            let finalState = MedicationActivityAttributes.ContentState(
                status: finalStatus,
                countdownTarget: countdownTarget,
                // W-B187 — the dismissal frame can render "Genommen um HH:mm", so
                // carry the time-format preference here too.
                timeFormatRaw: HLTimeFormat.current().rawValue
            )
            await activity.end(
                ActivityContent(state: finalState, staleDate: nil),
                dismissalPolicy: dismissalPolicy
            )
        }

        /// End **all** running medication Activities (e.g. on sign-out /
        /// account switch so no stale dose leaks across users).
        func endAll(dismissalPolicy: ActivityUIDismissalPolicy = .immediate) async {
            for activity in Activity<MedicationActivityAttributes>.activities {
                tokenStreamTasks.removeValue(forKey: activity.id)?.cancel()
                await activity.end(nil, dismissalPolicy: dismissalPolicy)
            }
        }

        // MARK: - Push-to-start token wiring

        /// Subscribe to push-to-start token updates and forward each to the
        /// sink. Call once on app launch (after notification authorisation)
        /// so the server can later drive `pushToStart` payloads. iOS 17.2+;
        /// on earlier OSes this is a silent no-op (we are on an iOS 18
        /// floor, so it always runs).
        func observePushToStartToken() {
            guard let tokenSink else { return }
            let key = "push-to-start"
            tokenStreamTasks[key]?.cancel()
            tokenStreamTasks[key] = _Concurrency.Task {
                for await tokenData in Activity<MedicationActivityAttributes>.pushToStartTokenUpdates {
                    let hex = tokenData.map { String(format: "%02x", $0) }.joined()
                    await tokenSink.didReceivePushToStartToken(hex)
                }
            }
        }

        /// Forward per-activity update tokens for a running Activity so the
        /// server can target updates at that specific Activity.
        private func observeUpdateToken(for activity: Activity<MedicationActivityAttributes>) {
            guard let tokenSink else { return }
            tokenStreamTasks[activity.id]?.cancel()
            let medicationId = activity.attributes.medicationId
            // Extract the (Sendable) token stream up front so the task does
            // not capture the non-`Sendable` `activity` value itself.
            let tokenUpdates = activity.pushTokenUpdates
            tokenStreamTasks[activity.id] = _Concurrency.Task {
                for await tokenData in tokenUpdates {
                    let hex = tokenData.map { String(format: "%02x", $0) }.joined()
                    await tokenSink.didReceiveActivityUpdateToken(hex, medicationId: medicationId)
                }
            }
        }

        // MARK: - Lookup

        /// `nonisolated` so the returned (non-`Sendable`) `Activity` value
        /// originates in a disconnected isolation region — that lets the
        /// async `update` / `end` calls in `update(...)` / `end(...)` await
        /// it without Swift 6 flagging "sending 'activity' risks data
        /// races" (the value never leaves a MainActor region because it was
        /// never in one). `Activity.activities` is itself `nonisolated`.
        private nonisolated func runningActivity(
            for medicationId: String
        ) -> Activity<MedicationActivityAttributes>? {
            Activity<MedicationActivityAttributes>.activities.first {
                $0.attributes.medicationId == medicationId
            }
        }
    }

    /// Sink for Live-Activity push tokens. Implemented by the
    /// `NotificationService` registration path (or a test double). Kept as a
    /// protocol so the controller never imports the notification stack.
    protocol LiveActivityPushTokenSink: Sendable {
        /// A fresh push-to-start token (hex). The server uses it to start a
        /// Live Activity remotely via APNs.
        func didReceivePushToStartToken(_ tokenHex: String) async
        /// A per-activity update token (hex) for a running Activity. The
        /// server uses it to push `update` / `end` to that Activity.
        func didReceiveActivityUpdateToken(_ tokenHex: String, medicationId: String) async
    }
#endif
