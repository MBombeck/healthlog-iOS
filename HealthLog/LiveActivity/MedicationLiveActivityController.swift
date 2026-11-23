#if canImport(ActivityKit)
    import ActivityKit
    import Foundation

    /// **Owns the medication Live Activity lifecycle.**
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
    /// **Spy-able seam for the reconcile routine.**
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

        /// #190 (20:09) — the server's dose window of a medication's slot
        /// (`dueAt`, `overdueSince`, `missedAfter` on today's row). Set by the
        /// container from the medication store; `nil` keeps the fallback.
        var doseBand: (@MainActor (_ medicationId: String, _ slot: Date) -> ServerDoseState?)?
        /// One scheduled local state change per running Activity.
        private var transitionTasks: [String: Task<Void, Never>] = [:]

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
        /// Activity for the same `medicationId` **and the same slot** is
        /// already running we **update** it in place instead of stacking a
        /// duplicate — the reconcile path can call this idempotently after
        /// every store load. A running Activity of the same medication for a
        /// different slot is ended and replaced: its static attributes name
        /// the old slot, and its "Taken" button would book that one.
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

            let decision = MedicationLiveActivityPlan.slotDecision(
                running: runningSlots(for: medicationId),
                requestedSlot: scheduledFireDate
            )
            switch decision {
            case let .reuse(id, endIDs):
                await endActivities(ids: endIDs)
                // Idempotent: an Activity already exists for this dose → update.
                guard let existing = activity(id: id) else { return nil }
                await update(
                    activityID: id,
                    status: .pending,
                    countdownTarget: scheduledFireDate,
                    isOverdue: isOverdue
                )
                // Only subscribe when nothing listens yet: re-subscribing on
                // every reconcile would cancel and restart the stream each load.
                if tokenStreamTasks[existing.id] == nil { observeUpdateToken(for: existing) }
                return existing.id
            case let .request(endIDs):
                await endActivities(ids: endIDs)
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
                // Carry the user's resolved 12h/24h/auto preference (the
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
                        // #190 (20:09): stale at `missedAfter`; the hand-over at
                        // the due time is the scheduled local change below.
                        staleDate: staleDate(medicationId: medicationId, slot: scheduledFireDate)
                    ),
                    pushType: tokenSink == nil ? nil : .token
                )
                HLLog.notifications.info("LiveActivity started med=\(medicationId, privacy: .private)")
                observeUpdateToken(for: activity)
                scheduleTransition(activityID: activity.id, medicationId: medicationId, slot: scheduledFireDate)
                return activity.id
            } catch {
                HLLog.notifications.error("LiveActivity request failed: \(error.localizedDescription)")
                return nil
            }
        }

        // MARK: - Update

        /// Update one running Activity's status + countdown target. No-op
        /// when that Activity is gone.
        private func update(
            activityID: String,
            status: MedicationActivityAttributes.ContentState.Status,
            countdownTarget: Date,
            isOverdue: Bool = false
        ) async {
            guard let activity = activity(id: activityID) else { return }
            let medicationId = activity.attributes.medicationId
            let slot = activity.attributes.scheduledFireDate
            let band = doseBand?(medicationId, slot)
            let state = MedicationActivityAttributes.ContentState(
                status: status,
                countdownTarget: countdownTarget,
                isOverdue: MedicationLiveActivityPlan.isOverdue(band: band, now: .now, fallback: isOverdue),
                // Re-resolve the current time-format preference on every
                // update so a mid-activity profile change (12h↔24h) propagates to
                // the Lock-Screen dose time.
                timeFormatRaw: HLTimeFormat.current().rawValue
            )
            // Await inline on the MainActor: the non-`Sendable` `activity`
            // never crosses a `Task` (sending) boundary, which keeps Swift 6
            // strict-concurrency happy without `@unchecked`/`assumeIsolated`.
            await activity.update(ActivityContent(
                state: state,
                staleDate: MedicationLiveActivityPlan.staleDate(countdownTarget: countdownTarget, now: .now, band: band)
            ))
            scheduleTransition(activityID: activityID, medicationId: medicationId, slot: slot)
        }

        private func staleDate(medicationId: String, slot: Date) -> Date {
            MedicationLiveActivityPlan.staleDate(countdownTarget: slot, now: .now, band: doseBand?(medicationId, slot))
        }

        /// Re-renders the Activity at the next instant of its window (the due
        /// time hands the countdown over, `overdueSince` turns it overdue),
        /// while the process lives; a later reconcile or a push takes over
        /// otherwise. One pending change per Activity.
        private func scheduleTransition(activityID: String, medicationId: String, slot: Date) {
            transitionTasks[activityID]?.cancel()
            guard let next = MedicationLiveActivityPlan.nextTransition(band: doseBand?(medicationId, slot), now: .now) else {
                transitionTasks[activityID] = nil
                return
            }
            transitionTasks[activityID] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(max(1, next.timeIntervalSinceNow)))
                guard !Task.isCancelled, let self, let activity = activity(id: activityID) else { return }
                let current = activity.content.state
                guard current.status == .pending else { return }
                await update(
                    activityID: activityID,
                    status: current.status,
                    countdownTarget: current.countdownTarget,
                    isOverdue: current.isOverdue
                )
            }
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
            let finalState = MedicationActivityAttributes.ContentState(
                status: finalStatus,
                countdownTarget: countdownTarget,
                // The dismissal frame can render "Genommen um HH:mm", so
                // carry the time-format preference here too.
                timeFormatRaw: HLTimeFormat.current().rawValue
            )
            for slot in runningSlots(for: medicationId) where slot.isLive {
                guard let activity = activity(id: slot.id) else { continue }
                await forgetUpdateToken(activityID: activity.id)
                await activity.end(
                    ActivityContent(state: finalState, staleDate: nil),
                    dismissalPolicy: dismissalPolicy
                )
            }
        }

        /// Ends the given Activities at once: they name a slot that is no
        /// longer the dose to show, so no confirmation frame belongs to them.
        private func endActivities(ids: [String]) async {
            for id in ids {
                guard let activity = activity(id: id) else { continue }
                await forgetUpdateToken(activityID: activity.id)
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }

        /// End **all** running medication Activities (e.g. on sign-out /
        /// account switch so no stale dose leaks across users).
        func endAll(dismissalPolicy: ActivityUIDismissalPolicy = .immediate) async {
            for activity in Activity<MedicationActivityAttributes>.activities {
                await forgetUpdateToken(activityID: activity.id)
                await activity.end(nil, dismissalPolicy: dismissalPolicy)
            }
        }

        // MARK: - Push-to-start token wiring

        /// Subscribe to push-to-start token updates and forward each to the
        /// sink. Call once on app launch (after notification authorisation)
        /// so the server can later drive `pushToStart` payloads.
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
        /// server can target updates at that specific Activity. Each token is
        /// reported with the Activity's id, medication and slot (#188 (2)), so
        /// the sink keeps one token per Activity instead of one per medication.
        private func observeUpdateToken(for activity: Activity<MedicationActivityAttributes>) {
            guard let tokenSink else { return }
            tokenStreamTasks[activity.id]?.cancel()
            let owner = LiveActivityTokenOwner(
                activityID: activity.id,
                medicationId: activity.attributes.medicationId,
                slot: activity.attributes.intakeScheduledFor
            )
            // Extract the (Sendable) values up front so the task does not
            // capture the non-`Sendable` `activity` value itself.
            let tokenUpdates = activity.pushTokenUpdates
            // Sends the token the Activity already has first: after a cold
            // start the stream need not repeat it, and the server would keep
            // the token of a gone Activity.
            let current = activity.pushToken
            tokenStreamTasks[activity.id] = _Concurrency.Task {
                if let current {
                    await tokenSink.didReceiveActivityUpdateToken(Self.hex(current), owner: owner)
                }
                for await tokenData in tokenUpdates {
                    await tokenSink.didReceiveActivityUpdateToken(Self.hex(tokenData), owner: owner)
                }
            }
        }

        private nonisolated static func hex(_ data: Data) -> String {
            data.map { String(format: "%02x", $0) }.joined()
        }

        /// Stops listening for an Activity's token and drops it from the sink,
        /// so an ended Activity's token is never the one the server gets.
        private func forgetUpdateToken(activityID: String) async {
            tokenStreamTasks.removeValue(forKey: activityID)?.cancel()
            await tokenSink?.didEndActivity(activityID: activityID)
        }

        /// **#188 (2) — re-subscribe at launch.** An Activity that outlived the
        /// process (started by this build or an older one) had no
        /// `pushTokenUpdates` listener after a cold start, so its token never
        /// reached the server again. Subscribes every live Activity and tells
        /// the sink which ones still exist, which drops the tokens of the rest.
        func resubscribeRunningActivities() async {
            guard let tokenSink else { return }
            var liveIDs: Set<String> = []
            for activity in Activity<MedicationActivityAttributes>.activities
                where activity.activityState == .active || activity.activityState == .stale
            {
                liveIDs.insert(activity.id)
                if tokenStreamTasks[activity.id] == nil { observeUpdateToken(for: activity) }
            }
            await tokenSink.retainActivities(ids: liveIDs)
        }

        // MARK: - Lookup

        /// `nonisolated` so the returned (non-`Sendable`) `Activity` value
        /// originates in a disconnected isolation region — that lets the
        /// async `update` / `end` calls in `update(...)` / `end(...)` await
        /// it without Swift 6 flagging "sending 'activity' risks data
        /// races" (the value never leaves a MainActor region because it was
        /// never in one). `Activity.activities` is itself `nonisolated`.
        private nonisolated func activity(id: String) -> Activity<MedicationActivityAttributes>? {
            Activity<MedicationActivityAttributes>.activities.first { $0.id == id }
        }

        /// The medication's Activities as plain values for the slot decision.
        /// Only `.active` and `.stale` count as live: an ended Activity can stay
        /// in `activities` while it fades and must not be reused for a new slot.
        private nonisolated func runningSlots(
            for medicationId: String
        ) -> [MedicationLiveActivityPlan.RunningSlot] {
            Activity<MedicationActivityAttributes>.activities
                .filter { $0.attributes.medicationId == medicationId }
                .map {
                    MedicationLiveActivityPlan.RunningSlot(
                        id: $0.id,
                        slot: $0.attributes.intakeScheduledFor,
                        isLive: $0.activityState == .active || $0.activityState == .stale
                    )
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
        func didReceiveActivityUpdateToken(_ tokenHex: String, owner: LiveActivityTokenOwner) async
        /// The Activity ended; its token must not be reported any more.
        func didEndActivity(activityID: String) async
        /// The Activities still running at launch; every other token goes.
        func retainActivities(ids: Set<String>) async
    }
#endif
