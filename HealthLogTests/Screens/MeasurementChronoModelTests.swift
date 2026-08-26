import Foundation
@testable import HealthLog
import Testing

/// Disambiguate the domain model from the HealthKit `Measurement` symbol that
/// the test module also resolves (same pattern as the sibling measurement tests).
private typealias Measurement = HealthLog.Measurement

/// v0.14.8 — chronological cross-category feed logic: chip strip composition,
/// per-chip filtering, and newest-first time sort.
@Suite("MeasurementChronoModel")
struct MeasurementChronoModelTests {
    private func make(
        _ kind: MetricKind,
        at: Date,
        id: String,
        scalar: Double = 1
    ) -> Measurement {
        Measurement(
            id: id,
            kind: kind,
            recordedAt: at,
            value: .scalar(scalar),
            source: .manual
        )
    }

    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("Empty feed yields no chips (→ empty state)")
    func emptyYieldsNoChips() {
        #expect(MeasurementChronoModel.chips(for: []).isEmpty)
    }

    @Test("Strip leads with All, then Core, then categories in order")
    func chipOrdering() {
        // weight → core (flat); hrv → heart; muscleMass → body.
        let rows = [
            make(.weight, at: base, id: "w"),
            make(.hrv, at: base, id: "h"),
            make(.muscleMass, at: base, id: "m")
        ]
        let chips = MeasurementChronoModel.chips(for: rows)
        #expect(chips.first == .all)
        #expect(chips.contains(.core))
        #expect(chips.contains(.category(.heart)))
        #expect(chips.contains(.category(.body)))
        // Body precedes heart in InsightsMetricCategory.allCases.
        let heartIdx = chips.firstIndex(of: .category(.heart))
        let bodyIdx = chips.firstIndex(of: .category(.body))
        if let h = heartIdx, let b = bodyIdx { #expect(b < h) }
        // Core sits between All and the first available category.
        let coreIdx = chips.firstIndex(of: .core)
        if let c = coreIdx, let b = bodyIdx { #expect(c < b) }
    }

    @Test("No Core chip when every kind is grouped")
    func noCoreWhenAllGrouped() {
        let rows = [make(.hrv, at: base, id: "h"), make(.muscleMass, at: base, id: "m")]
        let chips = MeasurementChronoModel.chips(for: rows)
        #expect(!chips.contains(.core))
        #expect(chips.first == .all)
    }

    @Test("All filter returns every row, newest-first")
    func allFilterSortsNewestFirst() {
        let rows = [
            make(.weight, at: base, id: "old"),
            make(.pulse, at: base.addingTimeInterval(3600), id: "new"),
            make(.hrv, at: base.addingTimeInterval(1800), id: "mid")
        ]
        let sorted = MeasurementChronoModel.rows(rows, filter: .all)
        #expect(sorted.map(\.id) == ["new", "mid", "old"])
    }

    @Test("Category filter restricts to that category's kinds")
    func categoryFilterScopes() {
        let rows = [
            make(.weight, at: base, id: "w"), // core
            make(.hrv, at: base, id: "h"), // heart
            make(.muscleMass, at: base, id: "m") // body
        ]
        let heart = MeasurementChronoModel.rows(rows, filter: .category(.heart))
        #expect(heart.map(\.id) == ["h"])
        let core = MeasurementChronoModel.rows(rows, filter: .core)
        #expect(core.map(\.id) == ["w"])
    }

    @Test("Equal-timestamp rows keep a deterministic order (id tie-break)")
    func stableTieBreak() {
        let rows = [
            make(.weight, at: base, id: "a"),
            make(.pulse, at: base, id: "c"),
            make(.hrv, at: base, id: "b")
        ]
        let sorted = MeasurementChronoModel.rows(rows, filter: .all)
        // Same timestamp → descending id.
        #expect(sorted.map(\.id) == ["c", "b", "a"])
    }

    // MARK: - D1 (#34) high-frequency-vital collapse (display-only)

    /// Build N pulse samples inside the SAME clock-minute, distinct ids +
    /// sub-minute timestamps, all rounding to the same `scalar`.
    private func pulseRun(count: Int, minute: Date, scalar: Double) -> [Measurement] {
        (0 ..< count).map { i in
            make(.pulse, at: minute.addingTimeInterval(Double(i)), id: "p\(i)", scalar: scalar)
        }
    }

    @Test("Ten same-minute same-value pulse samples collapse to one row, count 10")
    func collapseSameValue() {
        let minute = Date(timeIntervalSince1970: 1_700_000_000) // :00 boundary
        let samples = pulseRun(count: 10, minute: minute, scalar: 46)
        let entries = MeasurementChronoModel.entries(samples, filter: .all)
        #expect(entries.count == 1)
        guard case let .collapsed(_, collapsed) = entries[0] else {
            Issue.record("expected a collapsed entry")
            return
        }
        #expect(collapsed.count == 10)
        // Underlying samples are preserved — no data loss.
        #expect(entries[0].samples.count == 10)
        let label = MeasurementChronoModel.collapsedValueLabel(for: collapsed, unit: MetricKind.pulse.unit)
        #expect(label == "46 bpm · 10×")
    }

    @Test("Mixed-value same-minute pulse run shows a range + count")
    func collapseMixedValues() {
        let minute = Date(timeIntervalSince1970: 1_700_000_000)
        var samples = pulseRun(count: 3, minute: minute, scalar: 45)
        samples[1] = make(.pulse, at: minute.addingTimeInterval(1), id: "p1", scalar: 48)
        let entries = MeasurementChronoModel.entries(samples, filter: .all)
        #expect(entries.count == 1)
        guard case let .collapsed(_, collapsed) = entries[0] else {
            Issue.record("expected a collapsed entry")
            return
        }
        let label = MeasurementChronoModel.collapsedValueLabel(for: collapsed, unit: MetricKind.pulse.unit)
        #expect(label == "45–48 bpm · 3×")
    }

    @Test("A single pulse sample stays an unchanged single row")
    func singlePulseNotCollapsed() {
        let minute = Date(timeIntervalSince1970: 1_700_000_000)
        let entries = MeasurementChronoModel.entries(pulseRun(count: 1, minute: minute, scalar: 46), filter: .all)
        #expect(entries.count == 1)
        guard case .single = entries[0] else {
            Issue.record("expected a single entry")
            return
        }
    }

    @Test("Only an uncollapsed non-derived entry resolves an unambiguous editor target")
    func editorTargetIsUnambiguous() {
        let manual = make(.weight, at: base, id: "manual", scalar: 82)
        #expect(MeasurementChronoModel.ChronoEntry.single(manual).editableMeasurement?.id == "manual")

        let computed = Measurement(
            id: "computed",
            kind: .weight,
            recordedAt: base,
            value: .scalar(82),
            source: .computed
        )
        #expect(MeasurementChronoModel.ChronoEntry.single(computed).editableMeasurement == nil)

        let collapsed = pulseRun(count: 2, minute: base, scalar: 46)
        #expect(
            MeasurementChronoModel.ChronoEntry.collapsed(
                representative: collapsed[0],
                samples: collapsed
            ).editableMeasurement == nil
        )
    }

    @Test("Non-vital kinds in the same minute are NOT collapsed")
    func nonVitalNotCollapsed() {
        let minute = Date(timeIntervalSince1970: 1_700_000_000)
        // Two weight rows + two BP rows in the same minute — both low-frequency,
        // must each render as individual rows.
        let weights = [
            make(.weight, at: minute, id: "w0", scalar: 82),
            make(.weight, at: minute.addingTimeInterval(1), id: "w1", scalar: 83)
        ]
        let entries = MeasurementChronoModel.entries(weights, filter: .all)
        #expect(entries.count == 2)
        #expect(entries.allSatisfy { if case .single = $0 { true } else { false } })
    }

    @Test("Same-value pulse rows in DIFFERENT minutes stay separate")
    func differentMinutesNotCollapsed() {
        let m0 = Date(timeIntervalSince1970: 1_700_000_000)
        let m1 = m0.addingTimeInterval(120) // +2 min → distinct clock-minute
        let samples = [
            make(.pulse, at: m0, id: "a", scalar: 46),
            make(.pulse, at: m1, id: "b", scalar: 46)
        ]
        let entries = MeasurementChronoModel.entries(samples, filter: .all)
        #expect(entries.count == 2)
        #expect(entries.allSatisfy { if case .single = $0 { true } else { false } })
    }

    @Test("Collapse does not change the underlying measurement count (no data loss)")
    func noDataLoss() {
        let minute = Date(timeIntervalSince1970: 1_700_000_000)
        var all = pulseRun(count: 10, minute: minute, scalar: 46)
        all.append(make(.weight, at: minute, id: "w", scalar: 80))
        let entries = MeasurementChronoModel.entries(all, filter: .all)
        let recovered = entries.flatMap(\.samples)
        #expect(recovered.count == all.count)
        #expect(Set(recovered.map(\.id)) == Set(all.map(\.id)))
    }

    @Test("Respiratory rate clusters collapse too; runs are split by kind")
    func respiratoryCollapsesAndKindSplits() {
        let minute = Date(timeIntervalSince1970: 1_700_000_000)
        // 3 respiratory samples, then a pulse in the same minute → two runs.
        var samples: [Measurement] = (0 ..< 3).map {
            make(.respiratoryRate, at: minute.addingTimeInterval(Double($0)), id: "r\($0)", scalar: 14)
        }
        samples.append(make(.pulse, at: minute.addingTimeInterval(5), id: "px", scalar: 50))
        // Newest-first: pulse (t+5) leads, then the 3 respiratory (t+2..t+0).
        let entries = MeasurementChronoModel.entries(samples, filter: .all)
        #expect(entries.count == 2)
        // Pulse run is a single (count 1); respiratory run collapses to 3.
        let collapsedCounts = entries.compactMap { entry -> Int? in
            if case let .collapsed(_, s) = entry { return s.count }
            return nil
        }
        #expect(collapsedCounts == [3])
    }

    @Test("Shared value formatter renders scalar and blood-pressure")
    func formattedValue() {
        let weight = make(.weight, at: base, id: "w", scalar: 82.4)
        // Locale-independent: compose the expected scalar string the same way.
        // A360-5 — weight now renders 1-dp (matching the dashboard); 82.4 is
        // unchanged. `.standard` = canonical units = no conversion.
        let expectedScalar = "\(82.4.formatted(.number.precision(.fractionLength(1)))) \(MetricKind.weight.unit)"
        #expect(MeasurementChronoModel.formattedValue(weight, units: .standard) == expectedScalar)
        let bp = Measurement(
            id: "bp",
            kind: .bloodPressure,
            recordedAt: base,
            value: .bloodPressure(systolic: 120, diastolic: 80),
            source: .manual
        )
        #expect(MeasurementChronoModel.formattedValue(bp, units: .standard) == "120/80 \(MetricKind.bloodPressure.unit)")
    }
}
