import SwiftUI

/// **Build 6.2 — medication lifecycle (pause / reactivate / end).**
///
/// Split out of `EditMedicationSheet.swift` so that file stays under SwiftLint's
/// `file_length` + `type_body_length` budgets (pure code movement, no behaviour
/// change). The `@State` / `@Environment` members it drives are non-private on
/// the host struct for this extension's reach.
extension EditMedicationSheet {
    /// Pause / reactivate / end-course controls + the server `pausedAt` state.
    /// Pause and reactivate flip `active` (the server stamps / clears
    /// `pausedAt`); "Behandlung beenden" ends the course now on a server that
    /// offers it (`canEndCourse`), else sets `endsOn` to today, without
    /// archiving the row in either case. Each action dismisses on success via
    /// `onSaved` (the list re-reads the canonical row).
    var lifecycleSection: some View {
        Section {
            if medication.active {
                HLSettingsActionRow(icon: "pause.fill", title: "med.lifecycle.pause", presents: .confirm) {
                    Task { await runLifecycle { await store.pauseMedication(id: medication.id) } }
                }
                // End and Start follow `canEndCourse` / `canStartCourse`;
                // an older server offers End as before and no Start.
                if medication.offersEndCourse {
                    HLSettingsActionRow(icon: "stop.fill", title: "med.lifecycle.end", presents: .confirm) {
                        showEndConfirm = true
                    }
                }
                if medication.offersCourseStart {
                    HLSettingsActionRow(icon: "play.fill", title: "med.lifecycle.start", presents: .confirm) {
                        Task { await runLifecycle { await store.startCourse(id: medication.id) } }
                    }
                }
            } else {
                if let pausedAt = medication.pausedAt {
                    LabeledContent {
                        Text(pausedAt, style: .relative)
                            .foregroundStyle(HLText.secondary)
                    } label: {
                        HLRowTitle("med.lifecycle.paused.label")
                    }
                }
                HLSettingsActionRow(icon: "play.fill", title: "med.lifecycle.reactivate", presents: .confirm) {
                    Task { await runLifecycle { await store.reactivateMedication(id: medication.id) } }
                }
            }
            if let lifecycleError {
                HLFormErrorText(lifecycleError.userFacingDescription)
                    .font(.hlSubhead)
            }
        } header: {
            HLSectionHeader("med.lifecycle.section")
        } footer: {
            // One consequence the buttons do not show: a pause does not
            // count as missed. "Beenden" states its own in the confirmation;
            // "Reaktivieren" needs no sentence.
            if medication.active {
                Text("med.lifecycle.footer.active")
                    .font(.hlCaption)
            }
        }
        .hlFormRowSurface()
        .disabled(isProcessingLifecycle || isSaving)
        .hlConfirmDestructive(
            Text("med.lifecycle.end.confirm.title"),
            isPresented: $showEndConfirm,
            message: medication.serverEndsCourseNow
                ? Text("med.lifecycle.end.confirm.message.now")
                : Text("med.lifecycle.end.confirm.message"),
            confirm: Text(String(localized: "med.lifecycle.end.confirm.cta")),
            cancel: Text(String(localized: "med.lifecycle.end.confirm.cancel")),
            action: {
                Task { await runLifecycle { await store.endMedication(id: medication.id) } }
            }
        )
    }

    /// Runs a lifecycle mutation, then dismisses on success/queued or surfaces
    /// the error inline (mirrors `save()`'s outcome handling + haptics).
    func runLifecycle(_ action: () async -> MedicationsStore.WriteOutcome) async {
        guard !isProcessingLifecycle else { return }
        isProcessingLifecycle = true
        defer { isProcessingLifecycle = false }
        lifecycleError = nil
        let outcome = await action()
        switch outcome {
        case .success, .queued:
            saveTick &+= 1
            onSaved()
        case let .failed(err):
            lifecycleError = err
            saveErrorTick &+= 1
        }
    }
}
