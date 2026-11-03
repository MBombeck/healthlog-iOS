import Foundation

/// v0.14.3 C4 — the **pure builder** that maps the server `comprehensive`
/// digest + targets payload onto the canonical ``InsightsMetricStatusCard.Descriptor``
/// for ANY ``MetricKind``. Kept view-free so the honest-only contract (each slot
/// self-suppresses when the server carries no signal) is unit-testable without
/// standing up SwiftUI.
///
/// **Three honest source paths, one card:**
///   • **BP** — classification / pct / band / sys-dia average all come from the
///     digest's BP fields (`bpClassification`, `bpPctInTarget`, `bpTargets`,
///     `summaries["BLOOD_PRESSURE_SYS"/"…DIA"]`). The ESH guideline caption is
///     attached.
///   • **BMI** — WHO classification chip from `digest.bmiClassification`, value
///     from `digest.bmi` (BMI's summary key is `WEIGHT`, a *weight* average, so
///     we MUST NOT surface `summaries["WEIGHT"].avg30` as a BMI mean — the BMI
///     headline is the latest computed BMI only). No in-target pct / band today.
///   • **every other metric** — value from the server's 30-day mean
///     (`summaries[key].avg30` of the digest, else of the summaries slice),
///     chip + Zielband + in-target pct from the **targets payload**
///     (`TargetItem.classification.category` / `.range` / `daysInRange30d`). A
///     metric with no target carries none of those → the card degrades to
///     value-only, or suppresses entirely when even the value is absent.
///
/// **1.4 B4 — the average is an average.** The card sits under the heading
/// "30 Tage Durchschnitt". It used to fall back to the latest reading when the
/// digest had no `avg30`, which is every account without a configured AI
/// provider (the digest is consent-gated) and every type the digest did not
/// summarise: day strain and RMSSD showed today's value, a stopped SDNN its
/// June reading. The latest reading has its own card right above ("Letzte
/// Messung"); without a server mean this card has no headline.
enum InsightsMetricStatusDescriptor {
    /// Builds the descriptor for `kind` from the available server signal.
    /// - Parameters:
    ///   - kind: the metric whose page is rendering.
    ///   - digest: the `GET /api/insights/comprehensive` envelope (or `nil`).
    ///   - target: the matching `GET /api/insights/targets` row (or `nil`).
    ///   - latestValue: the latest charted reading (BMI's headline fallback
    ///     only; a generic metric never shows it as its 30-day average).
    ///   - sparklineValues: the chronological chart values (`store.chartPoints`)
    ///     used to draw the target-less **Verlauf** for non-targeted kinds
    ///     (v0.14.4 D1). `nil`/<2 points → no sparkline. BP keeps its full anatomy
    ///     and ignores this.
    ///   - serverAverage30: the summaries slice's `avg30` for this kind, used
    ///     when the digest carries none (1.4 B4).
    static func build(
        kind: MetricKind,
        digest: ComprehensiveDigest?,
        target: InsightsTargetsResponseDTO.TargetItem?,
        latestValue: Double?,
        sparklineValues: [Double]? = nil,
        units: UnitPreferences = .standard,
        serverAverage30: Double? = nil
    ) -> InsightsMetricStatusCard.Descriptor {
        switch kind {
        case .bloodPressure:
            buildBloodPressure(kind: kind, digest: digest)
        case .bmi:
            buildBMI(kind: kind, digest: digest, latestValue: latestValue, sparklineValues: sparklineValues)
        default:
            buildGeneric(
                kind: kind,
                digest: digest,
                // #20 — only the row whose band describes THIS kind's series. The
                // server `PULSE` row is the resting-pulse band: it may sit on the
                // resting card, never on the raw pulse card (HealthLog#584).
                target: target.flatMap { $0.type == MetricChartMath.bandTargetType(for: kind) ? $0 : nil },
                serverAverage30: serverAverage30,
                sparklineValues: sparklineValues,
                units: units
            )
        }
    }

    // MARK: - Blood pressure

    private static func buildBloodPressure(
        kind: MetricKind,
        digest: ComprehensiveDigest?
    ) -> InsightsMetricStatusCard.Descriptor {
        let sys = digest?.summaries?["BLOOD_PRESSURE_SYS"]?.avg30
        let dia = digest?.summaries?["BLOOD_PRESSURE_DIA"]?.avg30
        let headline: String? = if let sys, let dia {
            String(format: "%.0f/%.0f", sys, dia)
        } else {
            nil
        }
        let classification = digest?.bpClassification
        return InsightsMetricStatusCard.Descriptor(
            title: kind.displayName,
            guidelineCaption: String(localized: "insights.digest.bp.guideline.esh2023"),
            // 1.4.1 — the ESH caption is the claim's authority; make it the way
            // into ESH 2023 / ESC 2024 / ACC-AHA 2017 rather than a bare name.
            sourcesTopic: .bloodPressureClassification,
            chipLabel: classification.map(bpLabel),
            chipTone: classification.map(bpTone) ?? .neutral,
            // 1.0.3 (1.4.1, audit row 10) — "Hypertension grade 2" is a
            // diagnostic category name. The clause that says a category off
            // home readings is not one lived only in the Sources sheet; it now
            // rides on the card next to the chip.
            chipCaption: String(localized: "insights.metric.statusCard.notADiagnosis"),
            headlineValue: headline,
            unitCaption: kind.unit,
            pctInTarget: digest?.bpPctInTarget,
            // b183 coherence — `bpPctInTarget` is the server's TRAILING 90-DAY
            // share (ESH-2023 band, comprehensive route). Label it "90 T" so the
            // figure isn't read as the 30-day window the non-BP bars use.
            inTargetWindowLabel: digest?.bpPctInTarget != nil ? String(localized: "90d") : nil,
            targetBandCaption: digest?.bpTargets.flatMap(bpTargetBandCaption),
            // BP keeps its full chip+band+bar anatomy — no target-less Verlauf here.
            sparklineValues: nil,
            identifierSuffix: kind.rawValue
        )
    }

    private static func bpLabel(_ c: BPClassification) -> String {
        switch c {
        case .optimal: String(localized: "insights.digest.bp.optimal")
        case .normal: String(localized: "insights.digest.bp.normal")
        case .highNormal: String(localized: "High-normal")
        case .hypertensionGrade1: String(localized: "Hypertension grade 1")
        case .hypertensionGrade2: String(localized: "Hypertension grade 2")
        case .hypertensionGrade3: String(localized: "Hypertension grade 3")
        case .unknown: String(localized: "Unknown", comment: "BMI/BP classification — server token not recognised")
        }
    }

    /// **1.0.3 (App Review 1.4.1, audit row 10 / ruling R20)** — no home-reading
    /// category paints in `.critical`.
    ///
    /// The first pass moved only grade 3 out of the alarm tone, which left the
    /// scale reading backwards: grade 2 red, grade 3 amber. R20 settles it the
    /// other way — the alarm tone leaves the vocabulary entirely. A red chip on
    /// a 30-day average of the user's own home readings is the card at its most
    /// diagnosis-shaped, and it is the severity signal, not the category name,
    /// that carries the claim. The categories stay (they are cited, ESH 2023)
    /// and `.warning` still separates the hypertensive bands from the rest, so
    /// nothing is hidden — it simply stops shouting.
    private static func bpTone(_ c: BPClassification) -> HLBadge.Tone {
        switch c {
        case .optimal, .normal: .success
        case .highNormal: .info
        case .hypertensionGrade1, .hypertensionGrade2, .hypertensionGrade3: .warning
        case .unknown: .neutral
        }
    }

    /// #115 · 1.3 — the band caption states only the band the server sent.
    /// It used to fill a missing edge with an invented 120–129 / 70–79, so an
    /// account whose target the server did not resolve read a band nobody set.
    /// Any missing edge → no caption.
    static func bpTargetBandCaption(_ t: BPTargets) -> String? {
        guard let sysLow = t.sysLow, let sysHigh = t.sysHigh,
              let diaLow = t.diaLow, let diaHigh = t.diaHigh else { return nil }
        return String(localized: "insights.digest.bp.targetBand \(sysLow) \(sysHigh) \(diaLow) \(diaHigh)")
    }

    // MARK: - BMI (WHO)

    private static func buildBMI(
        kind: MetricKind,
        digest: ComprehensiveDigest?,
        latestValue: Double?,
        sparklineValues: [Double]?
    ) -> InsightsMetricStatusCard.Descriptor {
        // BMI's summary key is `WEIGHT`; surfacing that avg as a BMI mean would
        // be a lie. The honest BMI headline is the server-computed BMI value
        // (`digest.bmi`), falling back to the latest charted BMI reading.
        let value = digest?.bmi ?? latestValue
        let headline = value.map { $0.formatted(.number.precision(.fractionLength(1))) }
        let classification = digest?.bmiClassification
        return InsightsMetricStatusCard.Descriptor(
            title: kind.displayName,
            // 1.4.1 — the BMI chip and its band hint are WHO 2000 bands. BP has
            // always named its guideline in the header; BMI classified silently.
            // It now says whose bands these are, and the caption cites them.
            guidelineCaption: String(localized: "insights.digest.bmi.guideline.who2000"),
            sourcesTopic: .bmi,
            chipLabel: classification.map(bmiLabel),
            chipTone: classification.map(bmiTone) ?? .neutral,
            // 1.0.3 (1.4.1, audit row 10) — same qualifier as BP: "Obesity
            // class III" is a WHO category computed from the user's own
            // readings, not a diagnosis anyone made.
            chipCaption: String(localized: "insights.metric.statusCard.notADiagnosis"),
            headlineValue: headline,
            unitCaption: kind.unit,
            pctInTarget: nil,
            // BMI carries no In-Range bar, so no window label is needed.
            inTargetWindowLabel: nil,
            // The WHO band hint (e.g. "WHO 18.5 – 24.9") is the BMI Zielband.
            targetBandCaption: classification.map(bmiBandHint),
            // v0.14.4 D1 — BMI never gets an In-Range bar (no day-share target),
            // so it carries the target-less Verlauf too (operator: "BMI hat keinen
            // Verlauf"). The WHO band caption stays — that is honest reference.
            sparklineValues: sparklineValues,
            identifierSuffix: kind.rawValue
        )
    }

    private static func bmiLabel(_ c: BMIClassification) -> String {
        switch c {
        case .underweight: String(localized: "Underweight", comment: "BMI WHO classification label")
        case .normal: String(localized: "Normal weight", comment: "BMI WHO classification label")
        case .overweight: String(localized: "Overweight")
        case .obeseGradeI: String(localized: "Obesity class I", comment: "BMI WHO classification label")
        case .obeseGradeII: String(localized: "Obesity class II", comment: "BMI WHO classification label")
        case .obeseGradeIII: String(localized: "Obesity class III", comment: "BMI WHO classification label")
        case .unknown: String(localized: "Unknown", comment: "BMI/BP classification — server token not recognised")
        }
    }

    /// **1.0.3 (1.4.1, audit row 10 / ruling R20)** — see ``bpTone``: the WHO
    /// obesity classes keep their names and lose the alarm tone. The lower
    /// bands are untouched; they were never `.critical`.
    private static func bmiTone(_ c: BMIClassification) -> HLBadge.Tone {
        switch c {
        case .underweight: .warning
        case .normal: .success
        case .overweight: .warning
        case .obeseGradeI, .obeseGradeII, .obeseGradeIII: .warning
        case .unknown: .neutral
        }
    }

    private static func bmiBandHint(_ c: BMIClassification) -> String {
        switch c {
        case .underweight: String(localized: "WHO < 18.5", comment: "BMI WHO band range hint")
        case .normal: String(localized: "WHO 18.5 – 24.9", comment: "BMI WHO band range hint")
        case .overweight: String(localized: "WHO 25.0 – 29.9", comment: "BMI WHO band range hint")
        case .obeseGradeI: String(localized: "WHO 30.0 – 34.9", comment: "BMI WHO band range hint")
        case .obeseGradeII: String(localized: "WHO 35.0 – 39.9", comment: "BMI WHO band range hint")
        case .obeseGradeIII: String(localized: "WHO ≥ 40.0", comment: "BMI WHO band range hint")
        case .unknown: String(localized: "Classification unavailable", comment: "BMI — server classification token unknown")
        }
    }

    // MARK: - Generic (every other metric)

    private static func buildGeneric(
        kind: MetricKind,
        digest: ComprehensiveDigest?,
        target: InsightsTargetsResponseDTO.TargetItem?,
        serverAverage30: Double?,
        sparklineValues: [Double]?,
        units: UnitPreferences
    ) -> InsightsMetricStatusCard.Descriptor {
        // 1.4 B4 — the headline is the server's 30-day mean and nothing else:
        // the digest's, else the summaries slice's. No fallback to the latest
        // reading (see the type doc).
        let avg30 = kind.availabilitySummaryKey.flatMap { digest?.summaries?[$0]?.avg30 } ?? serverAverage30
        let headline = avg30.map { headlineText(kind: kind, avg30: $0, units: units) }

        // Chip + Zielband + in-target pct from the TARGETS payload — the only
        // honest per-metric classification source for non-BP/BMI metrics. All
        // self-suppress when the user has no target / sparse window.
        let chip = classificationChip(from: target)
        let pct = pctInTarget(from: target)
        let band = targetBandCaption(from: target, units: units)
        // v0.14.4 D1 — when there is NO clinical band/bar (a non-targeted kind such
        // as Aktive Energie + the ~25 other no-target kinds), still give the card a
        // **Verlauf** sparkline so it reads like Gewicht/Puls minus the band. We do
        // NOT fabricate a Zielband or an "Im Zielbereich" bar — honest trend only.
        // Targeted kinds (pct/band populated) keep their richer anatomy and skip it.
        // 1.4 B4 — the line rides with the average: without one there is no
        // card to carry it (the chart below draws the same points).
        let trend: [Double]? = (pct == nil && band == nil && headline != nil) ? sparklineValues : nil
        return InsightsMetricStatusCard.Descriptor(
            title: kind.displayName,
            guidelineCaption: nil,
            chipLabel: chip?.label,
            chipTone: chip?.tone ?? .neutral,
            headlineValue: headline,
            unitCaption: units.unitLabel(for: kind),
            pctInTarget: pct,
            // b183 coherence — the non-BP share rides the local 30-day day-count
            // window (`daysInRange30d / daysLogged30d`). Label it "30 T" so each
            // bar honestly carries its own window alongside BP's 90-day one.
            inTargetWindowLabel: pct != nil ? String(localized: "30d") : nil,
            targetBandCaption: band,
            sparklineValues: trend,
            identifierSuffix: kind.rawValue
        )
    }

    /// The classification chip from the target row's server-emitted category.
    /// Tone follows the most-recent consistency bucket (the most honest
    /// "where are we now" signal); neutral when the window is sparse.
    private static func classificationChip(
        from target: InsightsTargetsResponseDTO.TargetItem?
    ) -> (label: String, tone: HLBadge.Tone)? {
        guard let target,
              let classification = target.classification,
              !classification.category.isEmpty else { return nil }
        var tone: HLBadge.Tone = .neutral
        for bucket in target.consistency7d.reversed() {
            guard let bucket else { continue }
            switch bucket {
            case .inBand: tone = .success
            case .nearBand: tone = .warning
            case .outBand: tone = .critical
            case .unknown: tone = .neutral
            }
            break
        }
        return (classification.category, tone)
    }

    /// The in-target share from the target row's 30-day day-count window.
    /// `nil` when the user has no target, the window is `insufficientData`, or
    /// nothing was logged — the bar self-suppresses (no fake "Im Zielbereich").
    private static func pctInTarget(
        from target: InsightsTargetsResponseDTO.TargetItem?
    ) -> Int? {
        guard let target,
              target.range != nil,
              !target.insufficientData,
              target.daysLogged30d > 0 else { return nil }
        let share = Double(target.daysInRange30d) / Double(target.daysLogged30d) * 100
        return Int(share.rounded())
    }

    /// **#115 P2** — the card's headline in the account's unit. The server's
    /// 30-day average is canonical SI (glucose too). A kind whose transform
    /// leaves precision open keeps the prior 0…1-dp text.
    private static func headlineText(kind: MetricKind, avg30: Double, units: UnitPreferences) -> String {
        let identity: (Double) -> String = { $0.formatted(.number.precision(.fractionLength(0 ... 1))) }
        guard units.transform(for: kind).rescales else { return identity(avg30) }
        return MetricValueFormatter.account(avg30, kind: kind, units: units, identity: identity)
    }

    /// The Zielband caption from the target row's range. `nil` when the user has
    /// no target band configured. **#115 P2** — the canonical bounds convert
    /// into the account's unit (``TargetUnitDisplay``), the label follows.
    private static func targetBandCaption(
        from target: InsightsTargetsResponseDTO.TargetItem?,
        units: UnitPreferences
    ) -> String? {
        guard let target, let range = target.range else { return nil }
        let display = TargetUnitDisplay(type: target.type, serverUnit: target.unit, units: units)
        let unit = display.unit
        let lo = fmt(display.value(range.min))
        let hi = fmt(display.value(range.max))
        if unit.isEmpty {
            return String(localized: "Target: \(lo)–\(hi)")
        }
        return String(localized: "Target: \(lo)–\(hi) \(unit)")
    }

    /// Trim a trailing `.0` so whole-number bands read `120` not `120.0`.
    private static func fmt(_ value: Double) -> String {
        // SWEEP (W-CRASHGUARD) — a finite whole renders as an Int; a non-finite
        // OR out-of-`Int.range` bound (`1e30`, which equals its `.rounded()` and
        // IS finite) falls through to the fractional formatter via the
        // `Int(safeServer:)` nil-on-reject contract — never traps.
        if value == value.rounded(), let whole = Int(safeServer: value) {
            return String(whole)
        }
        return value.formatted(.number.precision(.fractionLength(1)))
    }
}
