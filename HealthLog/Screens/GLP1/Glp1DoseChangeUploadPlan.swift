import Foundation

/// **#169 — which local titration steps go up, with what, and what an answer
/// means for the local copy.** Pure, so the update path is testable without
/// a server or a store.
///
/// A step waits for its upload while its `serverID` is `nil`. Every row a 1.7
/// build wrote reads that way, so after the update each goes up exactly once:
/// the create carries the row's own id as `clientId`, and the server answers
/// a repeat with the stored step.
enum Glp1DoseChangeUploadPlan {
    /// What happens to the local copy after an upload attempt.
    enum Resolution: Equatable {
        /// The server holds the step under this id; mark the row.
        case markUploaded(serverID: String)
        /// The step was removed on the server (410); drop the local copy.
        case dropLocal
        /// Nothing settled (offline, a server error); try on the next load.
        case keepPending
    }

    /// The server's bounds (`glp1DoseChangePostSchema`): from 2020-01-01,
    /// at most five years ahead, a dose from 0 to 100, a note up to 500.
    static let earliestEffectiveFrom = Date(timeIntervalSince1970: 1_577_836_800)
    static let latestAhead: TimeInterval = 5 * 365 * 24 * 60 * 60
    static let maxDose: Double = 100
    static let maxNoteLength = 500
    private static let clientIdCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._:-"
    )

    /// The rows still to upload, oldest step first. A row the server would
    /// refuse by its schema stays on the device instead of failing on every
    /// load.
    static func pending(_ steps: [TitrationStepEntrySnapshot], now: Date = .now) -> [TitrationStepEntrySnapshot] {
        steps
            .filter { $0.serverID == nil && isUploadable($0, now: now) }
            .sorted { $0.effectiveFrom < $1.effectiveFrom }
    }

    static func isUploadable(_ step: TitrationStepEntrySnapshot, now: Date = .now) -> Bool {
        isValidClientId(step.id)
            && step.effectiveFrom >= earliestEffectiveFrom
            && step.effectiveFrom <= now.addingTimeInterval(latestAhead)
            && step.doseMg.isFinite && step.doseMg >= 0 && step.doseMg <= maxDose
    }

    static func isValidClientId(_ id: String) -> Bool {
        (1 ... 128).contains(id.count) && id.unicodeScalars.allSatisfy { clientIdCharacters.contains($0) }
    }

    /// The create body for a row: its own id as `clientId`, the dose in mg.
    static func body(for step: TitrationStepEntrySnapshot) -> Glp1DoseChangeCreate {
        Glp1DoseChangeCreate(
            effectiveFrom: step.effectiveFrom,
            doseValue: step.doseMg,
            doseUnit: "mg",
            note: step.note.map { String($0.prefix(maxNoteLength)) },
            clientId: step.id
        )
    }

    /// The server step that already carries this row's id, uploaded before
    /// the answer got lost. Marking it needs no request.
    static func serverStep(holding step: TitrationStepEntrySnapshot, in serverChanges: [Glp1DoseChangeDTO]) -> String? {
        serverChanges.first { $0.clientId == step.id }?.id
    }

    /// The local copy's fate after a create answered `result`.
    static func resolve(_ result: Result<Glp1DoseChangeDTO, Error>) -> Resolution {
        switch result {
        case let .success(stored):
            return .markUploaded(serverID: stored.id)
        case let .failure(error):
            if let error = error as? HLError, error.isGlp1DoseChangeDeleted { return .dropLocal }
            return .keepPending
        }
    }
}
