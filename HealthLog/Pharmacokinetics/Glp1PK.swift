import Foundation

/// GLP-1 pharmacokinetics — Swift port of
/// `src/lib/medications/glp1-pk.ts` (server v1.4.25 W19c).
///
/// **SCOPE LIMIT — read this before extending the file.**
///
/// This module implements a **one-compartment** first-order absorption +
/// first-order elimination Bateman model. It is suitable ONLY for
/// **qualitative** display surfaces — the "shot phase" chip (rising / peak /
/// fading) on the dashboard tile and the drug-level AreaChart on
/// `MedicationDetailScreen`, which the server made unconditional when it
/// retired Research Mode (D-12-05-A).
///
/// Two-compartment math is **explicitly out of scope**. Per
/// `glp1-pk.ts:18–43`:
///
/// 1. The journal-of-record (Schneck & Urva 2024, DOI 10.1002/psp4.13099)
///    confirms a two-compartment structure as the high-fidelity model.
///    Importing it into HealthLog would invite users to read off **numeric**
///    plasma concentrations — and numeric concentrations cross the EU MDR
///    Class I "predict / advise" threshold that HealthLog is engineered to
///    stay decisively below.
///
/// 2. The one-compartment closed form is sufficient to surface a qualitative
///    phase label (the chip only needs to know whether C(t) is climbing,
///    peaking, or decaying). The sawtooth shape of the superimposed
///    multi-dose curve is also adequate for the drug-level AreaChart,
///    which deliberately hides the y-axis tick labels and frames the line
///    as "Estimated level (relative)" — never "plasma concentration",
///    never with a unit.
///
/// If a future maintainer needs the two-compartment model (deferred to v1.5
/// per server-research §12.2), it must ship alongside (a) the v1.5
/// medical-device review, (b) a renewed Coach refusal-layer audit, and (c)
/// an explicit operator decision to keep the y-axis unit-less. Do NOT
/// add it as a silent refactor of this file.
///
/// **PURITY — this module has zero I/O.** No `Date.now` reads, no
/// dependency on storage or networking. Every function accepts an explicit
/// `asOf` so callers can render deterministic charts and tests can replay
/// the same dose history at any reference time.
public enum Glp1PK {
    // D-12-05-A — `researchModeDisclaimerVersionFallback` is gone. It stamped a
    // disclaimer the user acknowledged to unlock this curve; the server deleted
    // that acknowledgment, its endpoint and its own
    // `RESEARCH_MODE_DISCLAIMER_VERSION` in `0160052289e4`. The disclaimer that
    // survives is the caption under the chart, which needs no version because
    // nothing is acknowledged against it.

    /// A logged GLP-1 intake event reduced to the two fields the PK math
    /// needs. Caller adapts from `Glp1DetailsDTO.recentIntakes` +
    /// `Glp1DetailsDTO.doseChanges` to populate. Sendable so callers can
    /// build the list off-actor and hand it to the chart without copy.
    public struct DoseEvent: Sendable, Hashable {
        /// When the dose was administered (absolute time).
        public let takenAt: Date
        /// Dose in milligrams — pure mg, no unit conversion inside this
        /// module. Caller is responsible for normalising server units.
        public let doseMg: Double

        public init(takenAt: Date, doseMg: Double) {
            self.takenAt = takenAt
            self.doseMg = doseMg
        }
    }

    /// A single sample of the simulated concentration curve.
    ///
    /// - `tHours`: hours since `asOf` (negative for past samples, positive
    ///   for projected future).
    /// - `concentration`: **unit-less** qualitative estimate. The number has
    ///   no clinical meaning on its own; it is only useful when plotted as
    ///   a series so the user sees the sawtooth rising/falling shape. The
    ///   chart that consumes these MUST hide the Y-axis tick labels and
    ///   frame the axis as "Estimated level (relative)" — see
    ///   `MedicationDetailScreen` for the locked render rules.
    public struct Sample: Sendable, Hashable {
        public let tHours: Double
        public let concentration: Double

        public init(tHours: Double, concentration: Double) {
            self.tHours = tHours
            self.concentration = concentration
        }
    }

    /// Qualitative phase label for the dashboard chip (per `glp1-pk.ts:301`).
    /// Never surfaces a numeric concentration.
    public enum ShotPhase: String, Sendable, Hashable {
        /// Concentration is climbing toward its next peak.
        case rising
        /// Within ±10 % of the local maximum.
        case peak
        /// Concentration is decaying after the last peak.
        case fading
        /// No contributing doses inside the look-back window (e.g. user just
        /// started; chart cannot infer phase).
        case none
    }

    /// Window + step overrides for `curve(drug:doses:asOf:options:)`.
    public struct Options: Sendable, Hashable {
        /// How far back to start sampling, **hours**. Default 14 d.
        public let windowHoursBefore: Double
        /// How far forward to project, **hours**. Default 7 d.
        public let windowHoursAfter: Double
        /// Sample spacing, **hours**. Default 6 h.
        public let stepHours: Double

        public init(
            windowHoursBefore: Double = 14 * 24,
            windowHoursAfter: Double = 7 * 24,
            stepHours: Double = 6
        ) {
            self.windowHoursBefore = windowHoursBefore
            self.windowHoursAfter = windowHoursAfter
            self.stepHours = stepHours
        }

        public static let `default` = Options()
    }

    // MARK: - Curve

    /// Sample the one-compartment Bateman curve for a series of doses by
    /// linear superposition (`glp1-pk.ts:257-288` verbatim shape). Returns
    /// one `Sample` per step across the requested window.
    ///
    /// The math is intentionally simple — every clinical-decision-support
    /// boundary (GROUND RULE 9 + 15) is held back from this function: no
    /// projection of when the next dose will peak, no "should you escalate"
    /// inference, no individual prediction (the y-axis is unit-less).
    ///
    /// - Parameters:
    ///   - drug: Catalog drug-id (resolves Ka/Ke/Vd from the catalog).
    ///   - doses: Past + scheduled doses. Order does not matter; doses
    ///     outside the sampling window contribute 0 after enough half-lives.
    ///   - asOf: Reference "now" the window is anchored to.
    ///   - options: Window/step overrides. Default is two-weeks-back /
    ///     one-week-ahead at 6 h resolution.
    public static func curve(
        drug: GLP1DrugCatalog.DrugID,
        doses: [DoseEvent],
        asOf: Date,
        options: Options = .default
    ) -> [Sample] {
        let step = max(options.stepHours, 0.25)
        let windowBefore = options.windowHoursBefore
        let windowAfter = options.windowHoursAfter

        let asOfSeconds = asOf.timeIntervalSince1970
        let doseOffsets: [(offsetHours: Double, doseMg: Double)] = doses.map { dose in
            let offsetHours = (dose.takenAt.timeIntervalSince1970 - asOfSeconds) / 3600.0
            return (offsetHours, dose.doseMg)
        }

        var samples: [Sample] = []
        // Match the TS implementation: half-open inclusive on `t <= windowAfter`.
        var t = -windowBefore
        while t <= windowAfter + 1e-9 {
            var total = 0.0
            for dose in doseOffsets {
                total += singleDoseConcentration(
                    drug: drug,
                    doseMg: dose.doseMg,
                    tHours: t - dose.offsetHours
                )
            }
            samples.append(Sample(tHours: t, concentration: total))
            t += step
        }
        return samples
    }

    // MARK: - Phase

    /// Qualitative phase label at a single timepoint — surfaces the "shot
    /// phase" chip on dashboard tiles without exposing any numeric
    /// concentration. Mirrors `glp1-pk.ts:303-338`.
    public static func shotPhase(
        drug: GLP1DrugCatalog.DrugID,
        doses: [DoseEvent],
        asOf: Date
    ) -> ShotPhase {
        guard !doses.isEmpty else { return .none }
        let probeStepHours = 3.0
        let samples = curve(
            drug: drug,
            doses: doses,
            asOf: asOf,
            options: Options(
                windowHoursBefore: probeStepHours,
                windowHoursAfter: probeStepHours,
                stepHours: probeStepHours
            )
        )
        guard samples.count >= 3 else { return .none }
        let before = samples[0]
        let here = samples[1]
        let after = samples[2]
        guard here.concentration > 0 else { return .none }

        let peakWindow = max(before.concentration, after.concentration)
        let flatGradient = abs(after.concentration - before.concentration) < peakWindow * 0.02
        if flatGradient, here.concentration >= peakWindow * 0.99 {
            return .peak
        }
        return after.concentration > before.concentration ? .rising : .fading
    }

    // MARK: - Internal math (mirror of `glp1-pk.ts:194-233`)

    /// Single-dose Bateman concentration at time `tHours` after dose
    /// administration. Returns 0 for `tHours <= 0` (no contribution before
    /// the dose was injected).
    ///
    ///   C(t) = (F * D * Ka / (V * (Ka - Ke))) * (exp(-Ke t) - exp(-Ka t))
    ///
    /// L'Hôpital fallback `C(t) = (F * D * Ka / V) * t * exp(-Ka t)` when
    /// `Ka ≈ Ke` keeps the function total — unlikely to fire on real EMA
    /// values, but guards a future catalog edit from introducing a
    /// divide-by-zero.
    static func singleDoseConcentration(
        drug: GLP1DrugCatalog.DrugID,
        doseMg: Double,
        tHours: Double
    ) -> Double {
        guard tHours > 0 else { return 0 }
        let record = GLP1DrugCatalog.drug(for: drug)
        let ka = resolveKa(record: record)
        let ke = resolveKe(record: record)
        let f = record.pharmacology.bioavailability
        // `vdLitersPerKg` is per-kg; the chart is qualitative so a 70 kg
        // reference is fine — using the user's actual weight would be a
        // *correction* worth doing in v1.5 when individual numeric
        // concentrations are surfaced (which v0.4.0 deliberately doesn't).
        let referenceWeightKg = 70.0
        let v = record.pharmacology.vdLitersPerKg * referenceWeightKg
        guard v > 0 else { return 0 }

        if abs(ka - ke) < 1e-9 {
            return (f * doseMg * ka / v) * tHours * exp(-ka * tHours)
        }
        let scale = (f * doseMg * ka) / (v * (ka - ke))
        return scale * (exp(-ke * tHours) - exp(-ka * tHours))
    }

    /// Resolve `Ka` from the catalog. Falls back to the rule-of-thumb
    /// `Ka ≈ ln(2) * 3 / Tmax` when EMA does not publish a pop-PK Ka
    /// (`glp1-pk.ts:162-175`).
    static func resolveKa(record: GLP1DrugCatalog.DrugRecord) -> Double {
        if let ka = record.pharmacology.absorptionRateHourlyKa, ka > 0 {
            return ka
        }
        return (3 * .ln2) / max(record.pharmacology.tmaxHours, 1)
    }

    /// Resolve `Ke` from the catalog half-life. `glp1-pk.ts:181-187`.
    static func resolveKe(record: GLP1DrugCatalog.DrugRecord) -> Double {
        let halfLifeHours = record.pharmacology.halfLifeDays * 24.0
        return .ln2 / max(halfLifeHours, 1e-6)
    }
}

// MARK: - Constants

private extension Double {
    /// `ln(2)` matching the TS constant in `glp1-pk.ts:149`.
    static let ln2 = Foundation.log(2.0)
}
