import SwiftUI

extension SettingsHKSyncDiagnosticsScreen {
    /// Redacted direct-workout delivery snapshot. Counts and operational
    /// provenance only; never renders workout identifiers or health values.
    ///
    /// K1 — the rows used to borrow the server card's labels („Server-Urteil",
    /// „Liefert selbstständig") for the local outcome and the history import,
    /// and printed the enum spellings as values. Both now say what they are.
    var workoutDeliveryCard: some View {
        HLSettingsCard(
            icon: "figure.run",
            title: "Workout",
            subtitle: "settings.hkdiag.wakes_subtitle"
        ) {
            VStack(alignment: .leading, spacing: HLSpace.md) {
                statRow(
                    label: "settings.hkdiag.workout_observer",
                    value: registrationLabel
                )
                statRow(
                    label: "settings.hkdiag.summary_last_activity",
                    value: relativeOrNever(diagnostics.workout.lastAttemptedAt)
                )
                statRow(
                    label: "settings.hkdiag.workout_last_delivered",
                    value: relativeOrNever(diagnostics.workout.lastCompletedUsefulAt)
                )
                statRow(
                    label: "settings.hkdiag.server_trigger",
                    value: HKSyncDiagnosticsVocabulary.workoutSource(diagnostics.workout.lastSource)
                )
                statRow(
                    label: "settings.hkdiag.summary_samples_read",
                    value: workoutCountSummary
                )
                statRow(
                    label: "settings.hkdiag.workout_outcome",
                    value: workoutOutcomeLabel
                )
                statRow(
                    label: "settings.hkdiag.workout_backfill",
                    value: HKSyncDiagnosticsVocabulary.workoutBackfill(diagnostics.workout.backfillState)
                )
            }
        }
    }

    private var registrationLabel: String {
        switch diagnostics.workout.registrationState {
        case .succeeded:
            String(localized: "settings.hkdiag.status_ok")
        case .failed:
            String(localized: "settings.hkdiag.status_stuck")
        case .attempted, .notAttempted:
            String(localized: "settings.hkdiag.status_idle")
        }
    }

    /// Compact field legend for the operator protocol:
    /// Fetched / Mapped / Sent / Accepted / skipped (rejected).
    private var workoutCountSummary: String {
        let snapshot = diagnostics.workout
        return "F \(snapshot.fetchedTotal) · M \(snapshot.mappedTotal) · "
            + "S \(snapshot.sentTotal) · A \(snapshot.acceptedTotal) · X \(snapshot.skippedTotal)"
    }

    private var workoutOutcomeLabel: String {
        guard let failure = diagnostics.workout.lastFailure else {
            return diagnostics.workout.lastCompletedUsefulAt == nil
                ? String(localized: "settings.hkdiag.status_idle")
                : String(localized: "settings.hkdiag.status_ok")
        }
        return HKSyncDiagnosticsVocabulary.workoutFailure(failure)
    }
}
