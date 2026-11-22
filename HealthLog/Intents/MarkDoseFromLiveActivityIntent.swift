#if canImport(ActivityKit)
    import ActivityKit
    import AppIntents
    import Foundation

    /// **The medication Live-Activity "Genommen"
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
        static let title: LocalizedStringResource = "med.dose.action.take"
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

        /// **#188 (7) — one tap.** The button records on the first tap. The
        /// two-step confirm guarded against an accidental tap because nothing
        /// could undo it; the next open of the app now offers that undo
        /// (``ExternalTakeLog``), so the Lock Screen behaves like every other
        /// surface. A running Activity from an older build that is still armed
        /// (`pendingConfirm`) records on the next tap as well.
        @MainActor
        func perform() async throws -> some IntentResult {
            switch tapStep() {
            case .none:
                // No matching pending Activity (already confirmed / none
                // running) — pure no-op.
                return .result()
            case let .commit(confirming):
                await commit(confirming)
                return .result()
            }
        }

        @MainActor
        private func commit(
            _ confirming: MedicationActivityAttributes.ContentState
        ) async {
            // 1. Signed out nothing can be recorded, so no check is shown either.
            //    The Activity falls back to its plain button.
            let deps = IntentDependencies.resolve()
            guard IntentDependencies.isSignedIn(deps) else {
                await applyState(Self.reverted(from: confirming))
                return
            }

            // 2. Flip to confirmed IMMEDIATELY (optimistic) so the green check
            //    animates the instant the finger lifts — before the network.
            //    Each ActivityKit mutation is awaited inline inside a helper so
            //    the non-`Sendable` `Activity` never crosses a suspension point
            //    (keeps Swift 6 strict-concurrency happy without `@unchecked`).
            await applyState(confirming)

            // 3. Record server-first (idempotency-keyed, Outbox fallback) against
            //    the SCHEDULED instant — not "now" — so the row collapses onto the
            //    in-app card's row.
            var failure: Error?
            var receipt: ReminderIntakeReceipt?
            let idempotencyKey = IdempotencyKey()
            do {
                receipt = try await deps.medicationsRepo.recordFromReminderReturningReceipt(
                    medicationId: medicationId,
                    scheduledFor: scheduledFor,
                    status: .taken,
                    idempotencyKey: idempotencyKey
                )
            } catch {
                failure = error
                HLLog.notifications.error(
                    "LA mark-taken failed err=\(LogSanitizer.redact(String(describing: error)), privacy: .public)"
                )
            }
            // A queued write keeps the check (it is saved and will sync). A
            // dropped one takes it back, so the Lock Screen never claims a dose
            // that no ledger will ever see.
            guard Self.commitOutcome(signedIn: true, error: failure) == .recorded else {
                await applyState(Self.reverted(from: confirming))
                return
            }
            // R1 (1): bound to the row this tap wrote; `alreadyTaken` keeps
            // the check but logs nothing, so no undo can remove another take.
            ExternalTakeLog().record(
                medicationId: medicationId,
                scheduledFor: scheduledFor,
                source: .liveActivity,
                binding: ExternalTakeLog.Binding.forCommit(error: failure, receipt: receipt, idempotencyKey: idempotencyKey.raw)
            )

            // 4. Hold the green-check confirmation frame (~1.6 s — long enough to
            //    read the check + feel acknowledged, short enough not to linger),
            //    then end the Activity. `.after` lets the system fade it off the
            //    Lock Screen rather than yanking it.
            try? await _Concurrency.Task.sleep(for: .seconds(1.6))
            await endActivity(with: confirming)
        }

        /// Resolve what a tap on the running Activity does, mapping its current `ContentState` through the pure
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

        /// Pure, Activity-free decision for a tap — extracted so it is
        /// unit-testable without a live ActivityKit Activity.
        ///
        /// - `confirmed` already true → `.none` (idempotent; a stray tap on an
        ///   already-recorded dose does nothing).
        /// - otherwise → `.commit` with the dose flipped to `confirmed`/`.taken`,
        ///   armed (`pendingConfirm`, older builds) or not (#188 (7)).
        static func step(
            for state: MedicationActivityAttributes.ContentState,
            now _: Date = .now
        ) -> TapStep {
            guard state.confirmed == false else { return .none }
            var confirming = state
            confirming.status = .taken
            confirming.confirmed = true
            confirming.pendingConfirm = false
            confirming.pendingConfirmStartedAt = nil
            return .commit(confirming)
        }

        enum CommitOutcome: Equatable {
            /// Saved on the server or durably queued: the check stays.
            case recorded
            /// Nothing was saved: back to the plain button.
            case notRecorded
        }

        /// Pure rule behind the check: only a write that landed or sits in
        /// the outbox counts. Signed out or a non-retriable failure is not one.
        static func commitOutcome(signedIn: Bool, error: Error?) -> CommitOutcome {
            guard signedIn else { return .notRecorded }
            guard let error else { return .recorded }
            // #189 (6): taken already, elsewhere — the check is the truth.
            if error is MedicationAlreadyTaken { return .recorded }
            if let hlError = error as? HLError, hlError.shouldPersistToOutbox { return .recorded }
            return .notRecorded
        }

        /// The plain pending state a failed or signed-out commit returns to.
        static func reverted(
            from state: MedicationActivityAttributes.ContentState
        ) -> MedicationActivityAttributes.ContentState {
            var reverted = state
            reverted.status = .pending
            reverted.confirmed = false
            reverted.pendingConfirm = false
            reverted.pendingConfirmStartedAt = nil
            return reverted
        }

        /// Result of the tap decision. Carries the plain-value
        /// `ContentState` to push next, never an `Activity`.
        enum TapStep: Equatable {
            /// No actionable Activity (none running, or already confirmed).
            case none
            /// Record the intake + confirm + end.
            case commit(MedicationActivityAttributes.ContentState)
        }

        /// Push an updated `ContentState` to the running Activity. The lookup +
        /// `await` happen in one `nonisolated` body so the `Activity` value never
        /// leaves a MainActor region (it was never in one).
        @concurrent
        private nonisolated func applyState(_ state: MedicationActivityAttributes.ContentState) async {
            guard let activity = runningActivity() else { return }
            await activity.update(ActivityContent(state: state, staleDate: nil))
        }

        /// End the running Activity with the confirmed final frame, fading it off
        /// the Lock Screen shortly after.
        @concurrent
        private nonisolated func endActivity(with state: MedicationActivityAttributes.ContentState) async {
            guard let activity = runningActivity() else { return }
            await activity.end(
                ActivityContent(state: state, staleDate: nil),
                dismissalPolicy: .after(.now + 2)
            )
        }

        /// The live Activity of exactly this dose. A tap that arrives after the
        /// Activity was replaced for a later slot finds nothing and books nothing.
        private nonisolated func runningActivity() -> Activity<MedicationActivityAttributes>? {
            Activity<MedicationActivityAttributes>.activities.first {
                $0.attributes.medicationId == medicationId
                    && abs($0.attributes.intakeScheduledFor.timeIntervalSince(scheduledFor)) < 1
                    && ($0.activityState == .active || $0.activityState == .stale)
            }
        }
    }
#endif
