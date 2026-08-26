import Foundation
import Observation

/// Backing store for the titration-ladder section. Merges three sources:
///
/// 1. **Server-authoritative dose-change history** from
///    `Glp1DetailsDTO.doseChanges` — passed in at load time by
///    `MedicationDetailStore`, treated as read-only.
/// 2. **Local TitrationStepEntry rows** from `GLP1LocalRepository` —
///    user-editable journal entries that augment (or override on
///    timestamp overlap) the server history.
/// 3. **Catalog standard ladder** from `GLP1DrugCatalog.titrationStepsMg`
///    — surfaced as a static "übliche Folge-Stufe gemäß Hersteller-
///    Leitfaden" hint **after** the current step. Never an autonomous
///    recommendation (MDR boundary — see GROUND RULE 9 + 15).
///
/// Merge rule for (1) + (2): two rows from different sources within the
/// same calendar day count as one — local takes precedence (the user
/// just edited). Outside the same-day window, both rows surface
/// independently so a careful user can backfill server history with
/// notes locally.
@MainActor
@Observable
public final class TitrationLadderStore {
    public let medicationID: String
    public let catalogDrug: GLP1DrugCatalog.DrugRecord?
    /// Fallback current-dose hint (mg) parsed from the medication's headline
    /// `dose` string — used by the catalog ladder marker when no dose-change
    /// history is recorded yet. `nil` when the headline dose isn't parseable.
    public let headlineDoseMgHint: Double?

    public private(set) var localSteps: [TitrationStepEntrySnapshot] = []
    public private(set) var serverChanges: [Glp1DoseChangeDTO] = []
    public private(set) var error: HLError?
    public private(set) var isLoading: Bool = false

    private let repo: GLP1LocalRepository

    public init(
        medicationID: String,
        catalogDrug: GLP1DrugCatalog.DrugRecord?,
        repo: GLP1LocalRepository,
        headlineDoseMgHint: Double? = nil
    ) {
        self.medicationID = medicationID
        self.catalogDrug = catalogDrug
        self.repo = repo
        self.headlineDoseMgHint = headlineDoseMgHint
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
        } catch {
            self.error = .unknown(String(describing: error))
        }
    }

    public func add(effectiveFrom: Date, doseMg: Double, note: String?) async {
        do {
            let inserted = try await repo.addTitrationStep(
                medicationID: medicationID,
                effectiveFrom: effectiveFrom,
                doseMg: doseMg,
                note: note
            )
            localSteps = mergeSorted(existing: localSteps, inserted: inserted)
        } catch let err as HLError {
            error = err
        } catch {
            self.error = .unknown(String(describing: error))
        }
    }

    public func update(
        id: String,
        effectiveFrom: Date,
        doseMg: Double,
        note: String?
    ) async {
        do {
            try await repo.updateTitrationStep(
                id: id,
                effectiveFrom: effectiveFrom,
                doseMg: doseMg,
                note: note
            )
            localSteps = try await repo.titrationSteps(medicationID: medicationID)
        } catch let err as HLError {
            error = err
        } catch {
            self.error = .unknown(String(describing: error))
        }
    }

    public func delete(id: String) async {
        do {
            try await repo.deleteTitrationStep(id: id)
            localSteps.removeAll { $0.id == id }
        } catch let err as HLError {
            error = err
        } catch {
            self.error = .unknown(String(describing: error))
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
        let localBuckets = Dictionary(grouping: localSteps) { step in
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

    /// The catalog's next standard ladder step *after* the current dose
    /// — surfaced as informational copy only. Returns `nil` when:
    /// - no catalog drug is resolved,
    /// - no current step exists,
    /// - the current step is at or above the catalog max.
    public var nextStandardStepMg: Double? {
        guard let catalogDrug,
              let current = currentStep?.doseMg else { return nil }
        let steps = catalogDrug.titrationStepsMg
        // First step strictly greater than the current dose.
        return steps.first { $0 > current }
    }

    /// The resolved current dose (mg) for the catalog ladder marker: the
    /// latest recorded dose-change wins; otherwise the parsed headline-dose
    /// hint. `nil` when neither is known (the ladder then renders every rung
    /// as upcoming with the marker before the first step).
    public var resolvedCurrentDoseMg: Double? {
        currentStep?.doseMg ?? headlineDoseMgHint
    }

    /// The standard catalog escalation ladder, classified against the
    /// current dose into past / current / upcoming rungs — the data behind
    /// the "you-are-here" titration plan (web v1.18.5 parity). Empty (the
    /// self-suppress signal) for non-titrating meds: no catalog drug, or a
    /// ladder shorter than two rungs.
    public var catalogTimelineSteps: [TitrationCatalogTimeline.Step] {
        guard let catalogDrug else { return [] }
        return TitrationCatalogTimeline.resolve(
            ladderMg: catalogDrug.titrationStepsMg,
            currentDoseMg: resolvedCurrentDoseMg
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
