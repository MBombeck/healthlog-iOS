import Foundation
import Observation

/// Backing store for the titration-ladder section. Merges three sources:
///
/// 1. **Server dose-change history** from `Glp1DetailsDTO.doseChanges`,
///    passed in at load time by `MedicationDetailStore`. Since #169 (server
///    1.48.0) the server holds the steps: they are edited and removed through
///    `PATCH` / `DELETE …/glp1/dose-changes/{id}`.
/// 2. **Local TitrationStepEntry rows** from `GLP1LocalRepository` that still
///    wait for their upload (`serverID == nil`). Every such row goes up once,
///    under its own id as `clientId` (``Glp1DoseChangeUploadPlan``), and is
///    marked afterwards, so it is never sent twice. Rows a 1.7 build wrote
///    carry no marker and upload on the first load after the update.
/// 3. **Catalog standard ladder** from `GLP1DrugCatalog.titrationStepsMg`
///    — surfaced as the label's published schedule, truncated at the dose
///    the user has actually reached. 1.0.3 (App Review 1.4.2, ruling R10)
///    removed the "next standard step" hint that used to sit after the
///    current step: a mg figure computed from the user's own dose is a
///    dosage projection, and Guideline 1.4.2 reserves those. Nothing above
///    the current dose is derived or shown (MDR boundary — GROUND RULE 9 + 15).
///
/// Merge rule for (1) + (2): a waiting local row and a server row on the same
/// calendar day count as one, the local one shown (the person just entered
/// it). Without a server seam (tests, previews) the ladder stays local.
@MainActor
@Observable
public final class TitrationLadderStore {
    public let medicationID: String
    public let catalogDrug: GLP1DrugCatalog.DrugRecord?

    /// Every local row, uploaded ones included.
    public private(set) var localSteps: [TitrationStepEntrySnapshot] = []
    public private(set) var serverChanges: [Glp1DoseChangeDTO] = []
    public private(set) var error: HLError?
    public private(set) var isLoading: Bool = false

    private let repo: GLP1LocalRepository
    private var server: Glp1DoseChangeRepository? {
        repo.doseChangeServer
    }

    private var isUploading = false
    /// Local ids of steps deleted on the device whose create may still be
    /// on the way (#191): a create that lands afterwards is deleted again.
    private var deletedWhileUploading: Set<String> = []
    /// The upload a save started; the sheet does not wait for it.
    private var uploadTask: Task<Void, Never>?

    public init(
        medicationID: String,
        catalogDrug: GLP1DrugCatalog.DrugRecord?,
        repo: GLP1LocalRepository
    ) {
        self.medicationID = medicationID
        self.catalogDrug = catalogDrug
        self.repo = repo
    }

    /// Whether a step the server holds can be edited and removed here.
    public var canEditServerSteps: Bool {
        server != nil
    }

    // MARK: - Load + mutate

    public func load(serverChanges: [Glp1DoseChangeDTO]) async {
        self.serverChanges = serverChanges
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            localSteps = try await repo.titrationSteps(medicationID: medicationID)
        } catch let err as HLError {
            error = err
            return
        } catch {
            self.error = .unknown(String(describing: error))
            return
        }
        // The ladder shows at once; the waiting rows go up behind it.
        startUpload()
    }

    /// Sends every waiting local row once (#169). Quiet: a row that does not
    /// go up stays on the device and is sent again on the next load.
    func uploadPending() async {
        guard let server, !isUploading else { return }
        isUploading = true
        defer { isUploading = false }
        let pending = Glp1DoseChangeUploadPlan.pending(localSteps)
        guard !pending.isEmpty else { return }
        for step in pending {
            let resolution: Glp1DoseChangeUploadPlan.Resolution
            if let held = Glp1DoseChangeUploadPlan.serverStep(holding: step, in: serverChanges) {
                resolution = .markUploaded(serverID: held)
            } else {
                do {
                    let stored = try await server.create(
                        medicationID: medicationID,
                        step: Glp1DoseChangeUploadPlan.body(for: step)
                    )
                    if deletedWhileUploading.contains(step.id) {
                        // #191: the create passed the tombstone before the
                        // delete ran; delete it once more (idempotent).
                        try? await server.delete(medicationID: medicationID, clientId: step.id)
                        deletedWhileUploading.remove(step.id)
                        continue
                    }
                    adopt(stored)
                    resolution = Glp1DoseChangeUploadPlan.resolve(.success(stored))
                } catch {
                    resolution = Glp1DoseChangeUploadPlan.resolve(.failure(error))
                }
            }
            switch resolution {
            case let .markUploaded(serverID):
                try? await repo.markTitrationStepUploaded(localID: step.id, serverID: serverID)
            case .dropLocal:
                try? await repo.deleteTitrationStep(id: step.id)
            case .keepPending:
                continue
            }
        }
        if let reloaded = try? await repo.titrationSteps(medicationID: medicationID) {
            localSteps = reloaded
        }
    }

    /// Records a dose step. Answers `nil` once saved and the failure
    /// otherwise, so the sheet can stay open with the entry. The step is on
    /// the device first and goes up right after.
    @discardableResult
    public func add(effectiveFrom: Date, doseMg: Double, note: String?) async -> HLError? {
        do {
            let inserted = try await repo.addTitrationStep(
                medicationID: medicationID,
                effectiveFrom: effectiveFrom,
                doseMg: doseMg,
                note: note
            )
            localSteps = mergeSorted(existing: localSteps, inserted: inserted)
        } catch {
            return PenInventoryStore.hlError(error)
        }
        startUpload()
        return nil
    }

    /// Sends the waiting rows without holding the sheet: an offline send may
    /// wait for the network for a long time.
    private func startUpload() {
        guard server != nil else { return }
        let previous = uploadTask
        uploadTask = Task { [weak self] in
            await previous?.value
            await self?.uploadPending()
        }
    }

    /// Waits for an upload a save started (tests).
    func settleUpload() async {
        await uploadTask?.value
    }

    /// Changes a recorded step. Answers `nil` once saved and the failure
    /// otherwise. A step the server holds is corrected there.
    @discardableResult
    public func update(
        id: String,
        effectiveFrom: Date,
        doseMg: Double,
        note: String?
    ) async -> HLError? {
        if let server, serverChanges.contains(where: { $0.id == id }) {
            // The sheet sends every field; an emptied note clears it.
            let noteField: MedicationsRepository.PatchField<String> = note.map {
                .value(String($0.prefix(Glp1DoseChangeUploadPlan.maxNoteLength)))
            } ?? .null
            do {
                let updated = try await server.update(
                    medicationID: medicationID,
                    doseChangeID: id,
                    patch: Glp1DoseChangePatch(
                        effectiveFrom: effectiveFrom,
                        doseValue: min(max(doseMg, 0), Glp1DoseChangeUploadPlan.maxDose),
                        doseUnit: "mg",
                        note: noteField
                    )
                )
                adopt(updated)
                return nil
            } catch {
                return PenInventoryStore.hlError(error)
            }
        }
        do {
            try await repo.updateTitrationStep(
                id: id,
                effectiveFrom: effectiveFrom,
                doseMg: doseMg,
                note: note
            )
            localSteps = try await repo.titrationSteps(medicationID: medicationID)
        } catch {
            return PenInventoryStore.hlError(error)
        }
        startUpload()
        return nil
    }

    /// Deletes a step. A failure lands in ``error`` for the screen's banner.
    @discardableResult
    public func delete(id: String) async -> Bool {
        error = nil
        do {
            if let server, serverChanges.contains(where: { $0.id == id }) {
                try await server.delete(medicationID: medicationID, doseChangeID: id)
                serverChanges.removeAll { $0.id == id }
                try? await repo.deleteTitrationSteps(serverID: id)
                localSteps.removeAll { $0.serverID == id }
            } else {
                let waitingUpload = localSteps.contains { $0.id == id && $0.serverID == nil }
                try await repo.deleteTitrationStep(id: id)
                localSteps.removeAll { $0.id == id }
                // #191: the step may be on its way up; spend its clientId so
                // a create that lands later answers 410, and delete again if
                // it already passed (see ``uploadPending()``).
                if waitingUpload, let server {
                    if isUploading { deletedWhileUploading.insert(id) }
                    try? await server.delete(medicationID: medicationID, clientId: id)
                }
            }
            return true
        } catch {
            self.error = PenInventoryStore.hlError(error)
            return false
        }
    }

    /// Takes a step the server answered into the server list.
    private func adopt(_ stored: Glp1DoseChangeDTO) {
        if let index = serverChanges.firstIndex(where: { $0.id == stored.id }) {
            serverChanges[index] = stored
        } else {
            serverChanges.append(stored)
        }
    }

    // MARK: - Derived data

    /// Merged ascending timeline of dose changes. Used by the timeline
    /// view. Algorithm:
    /// - start with the union of server changes + local rows
    /// - within the same calendar day, local takes precedence
    /// - sort ascending by effective date
    public var mergedTimeline: [TitrationLadderEntry] {
        let calendar = Calendar.current
        // Uploaded rows are the server's now; only the waiting ones show.
        let localBuckets = Dictionary(grouping: localSteps.filter { $0.serverID == nil }) { step in
            calendar.startOfDay(for: step.effectiveFrom)
        }
        var combined: [TitrationLadderEntry] = []
        // Local rows always surface (newest creation wins within a day).
        for (_, rows) in localBuckets {
            if let latest = rows.max(by: { $0.createdAt < $1.createdAt }) {
                combined.append(TitrationLadderEntry(local: latest))
            }
        }
        // Server rows that don't share a day with a local row.
        for change in serverChanges {
            let day = calendar.startOfDay(for: change.effectiveFrom)
            if localBuckets[day] == nil {
                combined.append(TitrationLadderEntry(server: change))
            }
        }
        combined.sort { $0.effectiveFrom < $1.effectiveFrom }
        return combined
    }

    /// Most-recent step in the merged timeline. `nil` when there is no
    /// recorded history (greenfield case — UI surfaces "Noch kein
    /// Verlauf erfasst" empty state).
    public var currentStep: TitrationLadderEntry? {
        mergedTimeline.last
    }

    /// The label's standard schedule, truncated at the recorded current dose
    /// — the data behind the informational titration rows. Empty (the
    /// self-suppress signal) when there is no catalog drug, when the ladder is
    /// shorter than two rungs, or when nothing has been recorded yet: the
    /// schedule is anchored to what the user logged, never to a dose guessed
    /// from the medication's name (1.4.2, ruling R10).
    public var catalogTimelineSteps: [TitrationCatalogTimeline.Step] {
        guard let catalogDrug else { return [] }
        return TitrationCatalogTimeline.resolve(
            ladderMg: catalogDrug.titrationStepsMg,
            currentDoseMg: currentStep?.doseMg
        )
    }

    // MARK: - Internals

    private func mergeSorted(
        existing: [TitrationStepEntrySnapshot],
        inserted: TitrationStepEntrySnapshot
    ) -> [TitrationStepEntrySnapshot] {
        var merged = existing
        merged.append(inserted)
        merged.sort { $0.effectiveFrom < $1.effectiveFrom }
        return merged
    }
}

/// A single row in the merged timeline. Carries enough info for the row
/// renderer to label the source (local-editable vs server-authoritative).
public struct TitrationLadderEntry: Hashable, Identifiable, Sendable {
    public enum Source: Sendable {
        case local
        case server
    }

    public let id: String
    public let effectiveFrom: Date
    public let doseMg: Double
    public let note: String?
    public let source: Source

    init(local: TitrationStepEntrySnapshot) {
        id = local.id
        effectiveFrom = local.effectiveFrom
        doseMg = local.doseMg
        note = local.note
        source = .local
    }

    init(server: Glp1DoseChangeDTO) {
        id = server.id
        effectiveFrom = server.effectiveFrom
        doseMg = server.doseUnit.lowercased() == "mg" ? server.doseValue : server.doseValue
        note = server.note
        source = .server
    }
}
