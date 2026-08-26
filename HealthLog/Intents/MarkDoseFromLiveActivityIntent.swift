#if canImport(ActivityKit)
    import ActivityKit
    import AppIntents
    import Foundation

    /// **v0.10 W-LiveActivity-POLISH — the medication Live-Activity "Genommen"
    /// button.**
    ///
    /// Unlike the Siri/Spotlight ``MarkMedicationTakenIntent`` (which has no
    /// running Activity to update and returns a spoken dialog), this intent is a
    /// purpose-built `LiveActivityIntent` that **updates the running Activity's
    /// `ContentState` in-place** so the user sees the green-check confirmation on
    /// the Lock Screen — synchronously, on tap, *without the app foregrounding* —
    /// then ends the Activity after a brief confirmation frame. It runs in the
    /// widget-extension process via the shared Keychain token.
    ///
    /// **Why a dedicated intent:** the shipped Live-Activity button reused
    /// `MarkMedicationTakenIntent`, whose `perform()` records the dose server-first
    /// but never touches the Activity — so the only thing that flipped the banner
    /// to `.taken` was the *app-side* reconcile loop, which needs the app alive.
    /// From a suspended Lock Screen the tap therefore felt like "nothing happened":
    /// the countdown kept running, no check, the dose appeared unmarked. Flipping
    /// `ContentState.confirmed` from inside `perform()` is what turns the loved
    /// countdown into a loved *complete* interaction.
    ///
    /// **De-dupe fix:** records against ``scheduledFor`` (the dose's
    /// `intakeScheduledFor` instant), **not** `Date()` "now", so the row keys on
    /// `(medicationId, scheduledFor)` and collapses onto the same server row as a
    /// tap from the in-app card — and so the reconcile's minute-granular
    /// `isResolved` match sees the dose as resolved.
    ///
    /// No parallel *write* path: it calls the same
    /// `MedicationsRepository.recordFromReminder(...)` — idempotency-keyed, Outbox
    /// fallback on a retriable network error — that the in-app card, the Siri
    /// intent, and the notification action handler use.
    struct MarkDoseFromLiveActivityIntent: LiveActivityIntent {
        static let title: LocalizedStringResource = "la.med.action.taken"
        static let openAppWhenRun: Bool = false

        @Parameter(title: "Medication ID")
        var medicationId: String

        @Parameter(title: "Scheduled For")
        var scheduledFor: Date

        init() {}

        init(medicationId: String, scheduledFor: Date) {
            self.medicationId = medicationId
            self.scheduledFor = scheduledFor
        }

        /// Auto-revert window: how long the `pendingConfirm` ("Erneut tippen
        /// zum Bestätigen") state stays armed before it reverts to the plain
        /// "Genommen" button if no second tap lands. 4 s is long enough for a
        /// deliberate second tap, short enough that a stale armed button never
        /// lingers on the Lock Screen.
        static let pendingConfirmWindow: Duration = .seconds(4)

        @MainActor
        func perform() async throws -> some IntentResult {
            // LA2 — anti-accidental TWO-STEP tap-confirm. Resolve which step we
            // are on from the running Activity's current ContentState. One
            // accidental tap can therefore NEVER record an intake — the first
            // tap only arms the confirm state.
            switch tapStep() {
            case .none:
                // No matching pending Activity (already confirmed / none
                // running) — pure no-op.
                return .result()

            case let .arm(armed):
                // FIRST tap: flip to the pending-confirm state in-place. The
                // button relabels to "Erneut tippen zum Bestätigen"; NO intake
                // recorded yet. Then hold the window and auto-revert if the
                // second tap never came.
                await applyState(armed)
                try? await _Concurrency.Task.sleep(for: Self.pendingConfirmWindow)
                await revertIfStillPending(armed.pendingConfirmStartedAt)
                return .result()

            case let .commit(confirming):
                // SECOND tap (button was armed): actually record the dose.
                await commit(confirming)
                return .result()
            }
        }

        /// Step 2 of the two-step confirm — the real record + confirm + end.
        @MainActor
        private func commit(
            _ confirming: MedicationActivityAttributes.ContentState
        ) async {
            // 2. Flip to confirmed IMMEDIATELY (optimistic) so the green check
            //    animates the instant the finger lifts — before the network.
            //    Each ActivityKit mutation is awaited inline inside a helper so
            //    the non-`Sendable` `Activity` never crosses a suspension point
            //    (keeps Swift 6 strict-concurrency happy without `@unchecked`).
            await applyState(confirming)

            // 3. Record server-first (idempotency-keyed, Outbox fallback) against
            //    the SCHEDULED instant — not "now" — so the row collapses onto the
            //    in-app card's row.
            let deps = IntentDependencies.resolve()
            if IntentDependencies.isSignedIn(deps) {
                do {
                    try await deps.medicationsRepo.recordFromReminder(
                        medicationId: medicationId,
                        scheduledFor: scheduledFor,
                        status: .taken
                    )
                } catch {
                    // Retriable errors are already enqueued on the Outbox inside
                    // recordFromReminder; the check stays (optimistic) — the dose
                    // IS recorded, just not yet synced. Non-retriable: logged, the
                    // check stays (the user DID press taken).
                    HLLog.notifications.error(
                        "LA mark-taken failed err=\(LogSanitizer.redact(String(describing: error)), privacy: .public)"
                    )
                }
            }

            // 4. Hold the green-check confirmation frame (~1.6 s — long enough to
            //    read the check + feel acknowledged, short enough not to linger),
            //    then end the Activity. `.after` lets the system fade it off the
            //    Lock Screen rather than yanking it.
            try? await _Concurrency.Task.sleep(for: .seconds(1.6))
            await endActivity(with: confirming)
        }

        /// Resolve which step of the two-step confirm the running Activity is
        /// on, mapping its current `ContentState` through the pure
        /// ``MarkDoseFromLiveActivityIntent/step(for:)`` decision.
        ///
        /// `nonisolated` so the (non-`Sendable`) `Activity` originates in a
        /// disconnected isolation region — only the plain-value `ContentState`
        /// (inside `TapStep`) crosses back to the MainActor, never the Activity
        /// itself (mirrors `MedicationLiveActivityController.runningActivity`).
        private nonisolated func tapStep() -> TapStep {
            guard let activity = runningActivity() else { return .none }
            return Self.step(for: activity.content.state)
        }

        /// Pure, Activity-free decision for the two-step confirm state machine —
        /// extracted so it is unit-testable without a live ActivityKit Activity.
        ///
        /// - `confirmed` already true → `.none` (idempotent; a stray tap on an
        ///   already-recorded dose does nothing).
        /// - `pendingConfirm == false` → `.arm` with the same dose flipped into
        ///   the pending-confirm state (FIRST tap — no intake yet).
        /// - `pendingConfirm == true` → `.commit` with the dose flipped to
        ///   `confirmed`/`.taken` (SECOND tap — records the intake).
        static func step(
            for state: MedicationActivityAttributes.ContentState,
            now: Date = .now
        ) -> TapStep {
            guard state.confirmed == false else { return .none }
            if state.pendingConfirm {
                var confirming = state
                confirming.status = .taken
                confirming.confirmed = true
                confirming.pendingConfirm = false
                confirming.pendingConfirmStartedAt = nil
                return .commit(confirming)
            }
            var armed = state
            armed.pendingConfirm = true
            armed.pendingConfirmStartedAt = now
            return .arm(armed)
        }

        /// Result of the two-step decision. Carries the plain-value
        /// `ContentState` to push next, never an `Activity`.
        enum TapStep: Equatable {
            /// No actionable Activity (none running, or already confirmed).
            case none
            /// First tap — arm the pending-confirm state (no intake recorded).
            case arm(MedicationActivityAttributes.ContentState)
            /// Second tap — record the intake + confirm + end.
            case commit(MedicationActivityAttributes.ContentState)
        }

        /// Auto-revert the armed pending-confirm state if no second tap landed.
        /// Reverts only when the Activity is STILL in the same armed window
        /// (matching `pendingConfirmStartedAt`) and not yet confirmed — so a
        /// committed second tap, or a freshly re-armed window, is never clobbered.
        private nonisolated func revertIfStillPending(_ startedAt: Date?) async {
            guard let activity = runningActivity() else { return }
            let current = activity.content.state
            guard
                current.confirmed == false,
                current.pendingConfirm,
                current.pendingConfirmStartedAt == startedAt else
            {
                return
            }
            var reverted = current
            reverted.pendingConfirm = false
            reverted.pendingConfirmStartedAt = nil
            await activity.update(ActivityContent(state: reverted, staleDate: nil))
        }

        /// Push an updated `ContentState` to the running Activity. The lookup +
        /// `await` happen in one `nonisolated` body so the `Activity` value never
        /// leaves a MainActor region (it was never in one).
        private nonisolated func applyState(_ state: MedicationActivityAttributes.ContentState) async {
            guard let activity = runningActivity() else { return }
            await activity.update(ActivityContent(state: state, staleDate: nil))
        }

        /// End the running Activity with the confirmed final frame, fading it off
        /// the Lock Screen shortly after.
        private nonisolated func endActivity(with state: MedicationActivityAttributes.ContentState) async {
            guard let activity = runningActivity() else { return }
            await activity.end(
                ActivityContent(state: state, staleDate: nil),
                dismissalPolicy: .after(.now + 2)
            )
        }

        private nonisolated func runningActivity() -> Activity<MedicationActivityAttributes>? {
            Activity<MedicationActivityAttributes>.activities
                .first { $0.attributes.medicationId == medicationId }
        }
    }
#endif
