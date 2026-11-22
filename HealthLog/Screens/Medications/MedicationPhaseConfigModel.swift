import Observation
import SwiftUI

/// The reminder phases of one medication: the server's value, the draft the
/// phase sheet edits, and the state of the read and the save.
///
/// One model serves the reminder section and its sheet, so the sentence on
/// the page follows a save at once. "Reset to defaults" only fills the draft
/// with the server defaults, as on the web; nothing is written before "Save".
@MainActor
@Observable
final class MedicationPhaseConfigModel {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed
    }

    let medicationID: String
    private let repository: any MedicationPhaseConfigProviding

    private(set) var state: LoadState = .idle
    /// What the server holds (its defaults when nothing is stored).
    private(set) var saved: MedicationPhaseConfig?
    /// What the sheet shows and saves.
    var draft: MedicationPhaseConfig = .defaults
    /// Phases whose number field is empty or holds no number.
    private(set) var blankPhases: Set<MedicationReminderPhase> = []
    private(set) var isSaving = false
    /// One line under the phases after a failed save.
    private(set) var saveError: String?

    init(medicationID: String, repository: any MedicationPhaseConfigProviding) {
        self.medicationID = medicationID
        self.repository = repository
    }

    var isDirty: Bool {
        guard let saved else { return false }
        return draft != saved || !blankPhases.isEmpty
    }

    var canSave: Bool {
        state == .loaded && !isSaving && blankPhases.isEmpty && draft.phasesOutOfRange.isEmpty
    }

    /// Reads the phases. A failure keeps the sentence without its plan.
    func load() async {
        guard state != .loading else { return }
        state = .loading
        do {
            let config = try await repository.phaseConfig(medicationID: medicationID)
            saved = config
            draft = config
            blankPhases = []
            state = .loaded
        } catch {
            state = .failed
        }
    }

    /// The sheet opens on the server's value, never on a draft left behind.
    func beginEditing() {
        if let saved { draft = saved }
        blankPhases = []
        saveError = nil
    }

    func value(for phase: MedicationReminderPhase) -> Double? {
        blankPhases.contains(phase) ? nil : Double(draft[phase].value)
    }

    func setValue(_ value: Double?, for phase: MedicationReminderPhase) {
        saveError = nil
        guard let value else {
            blankPhases.insert(phase)
            return
        }
        blankPhases.remove(phase)
        draft[phase].value = Int(value.rounded())
    }

    func mode(for phase: MedicationReminderPhase) -> MedicationPhaseConfig.Mode {
        draft[phase].mode
    }

    func setMode(_ mode: MedicationPhaseConfig.Mode, for phase: MedicationReminderPhase) {
        saveError = nil
        draft[phase].mode = mode
    }

    func resetToDefaults() {
        draft = .defaults
        blankPhases = []
        saveError = nil
    }

    /// Saves the draft. `true` when the sheet may close.
    func save() async -> Bool {
        guard canSave else { return false }
        isSaving = true
        defer { isSaving = false }
        do {
            let stored = try await repository.savePhaseConfig(draft, medicationID: medicationID)
            saved = stored
            draft = stored
            saveError = nil
            AccessibilityNotification.Announcement(
                String(localized: "med.phases.saved", defaultValue: "Reminder phases saved")
            ).post()
            return true
        } catch let refusal as MedicationPhaseConfigRefusal {
            saveError = refusal.message
            return false
        } catch {
            saveError = String(localized: "med.phases.error.save", defaultValue: "Could not save the reminder phases.")
            return false
        }
    }
}
