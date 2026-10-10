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
                // U1 (#18) — fed by `lastCompletedUsefulAt`: the last batch the
                // server accepted in full, duplicates included. „Zuletzt
                // geliefert" read as "last new workout uploaded".
                statRow(
                    label: "settings.hkdiag.workout_last_accepted",
                    value: relativeOrNever(diagnostics.workout.lastCompletedUsefulAt)
                )
                statRow(
                    label: "settings.hkdiag.server_trigger",
                    value: HKSyncDiagnosticsVocabulary.workoutSource(diagnostics.workout.lastSource)
                )
                statRow(
                    label: "settings.hkdiag.workout_counts_label",
                    value: HKSyncDiagnosticsVocabulary.workoutCounts(diagnostics.workout)
                )
                statRow(
                    label: "settings.hkdiag.workout_outcome",
                    value: workoutOutcomeLabel
                )
                // #17 — the history-import row. Hidden while nothing reports.
                if let historyImport = workoutHistoryImportText {
                    statRow(label: "settings.hkdiag.workout_history_import", value: historyImport)
                }
                // U1 (#18) — this state is the heart-rate enrichment sweep
                // (`WorkoutHRBackfillSweep`), not the workout import; the old
                // „Verlaufsimport" label named the wrong thing.
                statRow(
                    label: "settings.hkdiag.workout_hr_backfill",
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

    /// **#17 seam (U1 → U2).** The one input of the history-import row: its
    /// value text, or `nil` to hide the row. U2's importer publishes
    /// `HKSyncDiagnostics.workoutHistoryImport`; `nil` means the importer has
    /// not seen a page since the update, so the row stays hidden.
    var workoutHistoryImportText: String? {
        diagnostics.workoutHistoryImport.map(Self.historyImportLabel)
    }

    /// Plain text for ``HKSyncDiagnostics/WorkoutHistoryImportStatus``.
    /// Static so the reworked diagnostics surface can reuse it unchanged.
    static func historyImportLabel(_ status: HKSyncDiagnostics.WorkoutHistoryImportStatus) -> String {
        guard status.isImporting else {
            return String(localized: "settings.hkdiag.workout_history_complete")
        }
        guard let remaining = status.remainingEstimate else {
            return String(localized: "settings.hkdiag.workout_history_importing")
        }
        return String(localized: "settings.hkdiag.workout_history_importing_remaining \(remaining)")
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
