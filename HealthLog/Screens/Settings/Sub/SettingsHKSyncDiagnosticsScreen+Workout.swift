import SwiftUI

extension SettingsHKSyncDiagnosticsScreen {
    /// Redacted direct-workout delivery snapshot. Counts and operational
    /// provenance only; never renders workout identifiers or health values.
    var workoutDeliveryCard: some View {
        HLSettingsCard(
            icon: "figure.run",
            title: "Workout",
            subtitle: "settings.hkdiag.wakes_subtitle"
        ) {
            VStack(alignment: .leading, spacing: HLSpace.md) {
                statRow(
                    label: "settings.hkdiag.wake_observer",
                    value: registrationLabel
                )
                statRow(
                    label: "settings.hkdiag.summary_last_activity",
                    value: relativeOrNever(diagnostics.workout.lastAttemptedAt)
                )
                statRow(
                    label: "settings.hkdiag.server_last_background",
                    value: relativeOrNever(diagnostics.workout.lastCompletedUsefulAt)
                )
                statRow(
                    label: "settings.hkdiag.server_trigger",
                    value: diagnostics.workout.lastSource?.rawValue ?? "—"
                )
                statRow(
                    label: "settings.hkdiag.summary_samples_read",
                    value: workoutCountSummary
                )
                statRow(
                    label: "settings.hkdiag.server_verdict",
                    value: workoutOutcomeLabel
                )
                statRow(
                    label: "settings.hkdiag.server_autonomy",
                    value: diagnostics.workout.backfillState.rawValue
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
        return failure.rawValue
    }
}
