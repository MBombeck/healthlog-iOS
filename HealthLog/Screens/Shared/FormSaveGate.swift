import Foundation
import Observation

/// The save state of one form sheet: whether a save is running and what the
/// last one failed with.
///
/// A sheet asks it to run its save and closes only when ``submit(_:)`` answers
/// `true`. A second tap while the first save is still running is ignored, so a
/// slow network cannot turn one entry into two. A failure stays in ``error``
/// for the sheet to show, and the sheet stays open with the entry intact.
@MainActor
@Observable
final class FormSaveGate {
    private(set) var isSaving = false
    private(set) var error: HLError?

    /// Runs `operation` unless a save is already in flight. The operation
    /// answers `nil` when it saved and the error otherwise.
    ///
    /// - Returns: `true` when the entry was saved and the sheet may close.
    func submit(_ operation: () async -> HLError?) async -> Bool {
        guard !isSaving else { return false }
        isSaving = true
        error = nil
        defer { isSaving = false }
        if let failure = await operation() {
            error = failure
            return false
        }
        return true
    }

    /// Drops a shown failure, for example once the person edits the form again.
    func clearError() {
        error = nil
    }
}
