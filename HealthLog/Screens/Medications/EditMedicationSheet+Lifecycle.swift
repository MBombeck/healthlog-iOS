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
    /// `pausedAt`); "Behandlung beenden" sets `endsOn` to today so the cadence
    /// stops without archiving the row. Each action dismisses on success via
    /// `onSaved` (the list re-reads the canonical row).
    var lifecycleSection: some View {
        Section {
            if medication.active {
                Button {
                    Task { await runLifecycle { await store.pauseMedication(id: medication.id) } }
                } label: {
                    Label("med.lifecycle.pause", systemImage: "pause.circle")
                }
                Button {
                    showEndConfirm = true
                } label: {
                    Label("med.lifecycle.end", systemImage: "stop.circle")
                }
            } else {
                if let pausedAt = medication.pausedAt {
                    LabeledContent("med.lifecycle.paused.label") {
                        Text(pausedAt, style: .relative)
                            .foregroundStyle(HLText.secondary)
                    }
                }
                Button {
                    Task { await runLifecycle { await store.reactivateMedication(id: medication.id) } }
                } label: {
                    Label("med.lifecycle.reactivate", systemImage: "play.circle")
                }
            }
            if let lifecycleError {
                HLFormErrorText(lifecycleError.userFacingDescription)
                    .font(.hlSubhead)
            }
        } header: {
            Text("med.lifecycle.section")
        } footer: {
            Text(medication.active ? "med.lifecycle.footer.active" : "med.lifecycle.footer.paused")
                .font(.hlCaption)
        }
        .disabled(isProcessingLifecycle || isSaving)
        .hlConfirmDestructive(
            Text("med.lifecycle.end.confirm.title"),
            isPresented: $showEndConfirm,
            message: Text("med.lifecycle.end.confirm.message"),
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
