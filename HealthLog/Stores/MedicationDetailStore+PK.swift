// PK-chart input split out of MedicationDetailStore.swift (pure move, W-FILELEN).
import Foundation

extension MedicationDetailStore {
    // MARK: - 14-02 (A3) — the section's three states

    /// **14-02 (A3) — what the drug-level section renders, decided by the store.**
    ///
    /// The section used to have exactly two branches: no doses → placeholder,
    /// doses → chart. That was a deliberate 12-10 decision (no skeleton zoo),
    /// made about a section whose input was assumed to be there. It is not:
    /// `intakes` arrives as a first page plus up to 80 sequential drain pages,
    /// so the section was handed a partial dose set, drew it as if it were the
    /// finished curve, and then swapped it for a taller one — the operator's A3
    /// ("lädt immer nach und springt dann ins Bild hinein").
    ///
    /// One loading branch with reserved height is a statement about a section
    /// whose input is KNOWN to arrive late, not a skeleton zoo, and the store
    /// already knows when the drain is done.
    public enum DrugLevelSection: Equatable, Sendable {
        /// The intake collection is still in flight. Reserved height, no curve.
        case loading
        /// Settled, and there is nothing to draw.
        case empty
        /// Settled, computed exactly once for this input.
        case curve(DrugLevelCurve)
    }

    /// One settled PK curve and everything the section renders from it.
    ///
    /// Carries the accessibility phase classification too, because
    /// `Glp1PK.shotPhase` runs a whole probe curve per sample: building it in
    /// the view's descriptor was an O(samples × doses × probe) recompute on
    /// every body pass. It is computed once here, off the render path, and the
    /// view maps the closed-set phases onto localized strings.
    public struct DrugLevelCurve: Equatable, Sendable {
        public let doses: [Glp1PK.DoseEvent]
        public let samples: [Glp1PK.Sample]
        /// One entry per `samples` element, same order.
        public let phases: [Glp1PK.ShotPhase]
        /// The instant the curve is anchored to. Captured once so the curve
        /// does not slide under the reader.
        public let asOf: Date

        public init(
            doses: [Glp1PK.DoseEvent],
            samples: [Glp1PK.Sample],
            phases: [Glp1PK.ShotPhase],
            asOf: Date
        ) {
            self.doses = doses
            self.samples = samples
            self.phases = phases
            self.asOf = asOf
        }
    }

    /// The window the drug-level chart draws: 21 d back, no projection, 6 h
    /// step — web parity (2026-07-18), unchanged by 14-02. It moved from the
    /// view to the store together with the computation it parameterizes.
    public nonisolated static let drugLevelChartOptions = Glp1PK.Options(
        windowHoursBefore: 21 * 24,
        windowHoursAfter: 0,
        stepHours: 6
    )

    // MARK: - PK chart input

    /// Build the `DoseEvent` list the PK math consumes. Per-intake dose
    /// resolution uses the dose-change history (`details.doseChanges` —
    /// most-recent change effective ≤ takenAt). Falls back to parsing the
    /// medication's headline `dose` string (`"7.5 mg"` → 7.5) when no
    /// dose-change is recorded.
    ///
    /// Filters out skipped events and any intake with `takenAt == nil`.
    ///
    /// **14-02 (A3) — settled inputs only.** While the intake collection is
    /// still being drained this returns `[]` rather than the partial set: a
    /// dose set that is still growing is not a curve, and handing it out is
    /// what made the section draw one curve per drain page. The section reads
    /// ``drugLevelSection`` instead, which distinguishes "still collecting"
    /// from "collected, and empty".
    public func pkDoseEvents() -> [Glp1PK.DoseEvent] {
        guard hasSettledIntakeCollection else { return [] }
        return settledDoseEvents()
    }

    /// The dose derivation itself, ungated. Same body `pkDoseEvents()` always
    /// had; the gate above is the only thing 14-02 added in front of it.
    func settledDoseEvents() -> [Glp1PK.DoseEvent] {
        let history = (details?.doseChanges ?? []).sorted { $0.effectiveFrom < $1.effectiveFrom }
        let headlineDoseMg = Self.parseHeadlineDose(medication.dose)

        return intakes
            .compactMap { event -> Glp1PK.DoseEvent? in
                guard !event.skipped, let takenAt = event.takenAt else { return nil }
                let doseMg = doseAt(takenAt, history: history) ?? headlineDoseMg
                guard let mg = doseMg, mg > 0 else { return nil }
                return Glp1PK.DoseEvent(takenAt: takenAt, doseMg: mg)
            }
    }

    // MARK: - 14-02 (A3) — the memoized compute

    /// Compute the settled curve ONCE and publish it, fenced.
    ///
    /// Called exactly where the input settles — right after
    /// `drainRemainingIntakes()` — and never from a render path. The compute
    /// runs off the main actor because it is pure arithmetic over `Sendable`
    /// values and because `Glp1PK.shotPhase` costs a probe curve per sample;
    /// the publication is a comparison against the generation the compute
    /// started in, so a curve computed for a superseded input set publishes
    /// nothing (09-04's presenter shape, the same one the rest of the app
    /// uses).
    func recomputeDrugLevelSection() async {
        let generation = pkGeneration
        guard hasSettledIntakeCollection, let drugID = drug?.id else {
            drugLevelSection = .empty
            return
        }
        let doses = settledDoseEvents()
        guard !doses.isEmpty else {
            drugLevelSection = .empty
            return
        }
        let asOf = Date.now
        let curve = await Task.detached(priority: .userInitiated) {
            Self.makeDrugLevelCurve(drug: drugID, doses: doses, asOf: asOf)
        }.value
        onDrugLevelCurveComputed?()
        guard generation == pkGeneration else { return }
        drugLevelSection = .curve(curve)
    }

    /// Pure + `nonisolated`, so the compute can leave the main actor. Byte-for-
    /// byte the arithmetic the view used to run in `var samples` and in
    /// `buildDescriptor`'s phase loop — only the call site moved.
    nonisolated static func makeDrugLevelCurve(
        drug: GLP1DrugCatalog.DrugID,
        doses: [Glp1PK.DoseEvent],
        asOf: Date
    ) -> DrugLevelCurve {
        let samples = Glp1PK.curve(
            drug: drug,
            doses: doses,
            asOf: asOf,
            options: drugLevelChartOptions
        )
        let phases = samples.map { sample in
            Glp1PK.shotPhase(
                drug: drug,
                doses: doses,
                asOf: asOf.addingTimeInterval(sample.tHours * 3600)
            )
        }
        return DrugLevelCurve(doses: doses, samples: samples, phases: phases, asOf: asOf)
    }

    /// Every exit of `load()` settles the section, so it can never strand on
    /// `.loading` — the Phase-13 lesson applied before it can bite. A load that
    /// threw before the drain leaves the section empty, which is what the
    /// two-branch section rendered on that path anyway.
    func settleDrugLevelSectionIfStillLoading() {
        if case .loading = drugLevelSection { drugLevelSection = .empty }
    }

    /// Find the most-recent dose-change effective ≤ the given timestamp.
    /// Returns the dose in mg (assumes the catalog stores values in mg —
    /// per `Glp1DoseChangeDTO`, `doseUnit` is recorded but other units are
    /// rare for GLP-1; if a future record uses µg or IU, the conversion
    /// would happen here).
    ///
    /// QC-4 reconcile: previously a non-mg recent change (e.g. a stray "µg"
    /// row) returned `nil` *and* aborted the search, masking the older mg
    /// change that should have applied. Now a non-mg row falls through to
    /// the next older change.
    private func doseAt(_ takenAt: Date, history: [Glp1DoseChangeDTO]) -> Double? {
        // History is ascending; walk back from the end.
        for change in history.reversed() where change.effectiveFrom <= takenAt {
            guard change.doseUnit.lowercased() == "mg" else { continue }
            return change.doseValue
        }
        return nil
    }
}
