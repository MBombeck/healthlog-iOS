import Foundation
@testable import HealthLog
import Testing

/// Disambiguate from Foundation.Measurement<Unit> — HealthLog ships its
/// own domain Measurement.
private typealias Measurement = HealthLog.Measurement

/// v0.5.5.1 — pin the contract of `MeasurementListFilter.apply(...)`. The
/// drill-down `MeasurementListScreen(kind:)` mounts both a `.searchable`
/// query and a per-source chip row; the filter pipeline restricts by
/// source first, then by the trimmed lowercased query needle. Locking the
/// rules here means a future regression — e.g. flipping the precedence or
/// quietly dropping the empty-query short-circuit — surfaces in CI before
/// operator hits it on device.
@Suite("MeasurementListFilter.apply — v0.5.5.1 source chip + search")
struct MeasurementListScreenFilterTests {
    private let now = Date(timeIntervalSince1970: 1_716_800_000) // 2024-05-27 UTC

    private func measurement(
        id: String,
        source: MeasurementSource,
        note: String? = nil,
        daysAgo: Int = 0,
        value: Double = 80
    ) -> Measurement {
        let recorded = Calendar(identifier: .gregorian)
            .date(byAdding: .day, value: -daysAgo, to: now) ?? now
        return Measurement(
            id: id,
            kind: .weight,
            recordedAt: recorded,
            value: .scalar(value),
            note: note,
            source: source
        )
    }

    @Test("Empty query + nil source filter returns every input row")
    func emptyQueryShowsAll() {
        let items: [Measurement] = [
            measurement(id: "a", source: .appleHealth),
            measurement(id: "b", source: .withings),
            measurement(id: "c", source: .manual)
        ]
        let result = MeasurementListFilter.apply(items, source: nil, query: "")
        #expect(result.count == 3)
        #expect(result.map(\.id) == ["a", "b", "c"])
    }

    @Test("Source chip restricts the list to rows matching the picked source")
    func sourceChipRestricts() {
        let items: [Measurement] = [
            measurement(id: "a", source: .appleHealth),
            measurement(id: "b", source: .withings),
            measurement(id: "c", source: .withings),
            measurement(id: "d", source: .manual)
        ]
        let result = MeasurementListFilter.apply(items, source: .withings, query: "")
        #expect(result.count == 2)
        #expect(Set(result.map(\.id)) == Set(["b", "c"]))
    }

    @Test("Search query further restricts on top of source chip")
    func searchRestrictsFurther() {
        let items: [Measurement] = [
            // Same source so the chip lets all three through; the query
            // needle then has to drop the row without a matching note.
            measurement(id: "a", source: .manual, note: "morgens nüchtern"),
            measurement(id: "b", source: .manual, note: "nach dem Sport"),
            measurement(id: "c", source: .manual, note: nil),
            // Different source — should be dropped by the chip layer first.
            measurement(id: "d", source: .appleHealth, note: "morgens nüchtern")
        ]
        let result = MeasurementListFilter.apply(items, source: .manual, query: "morgens")
        #expect(result.count == 1)
        #expect(result.first?.id == "a")
    }

    // MARK: - v1.18.5 value-range filter

    private func rangeItems() -> [Measurement] {
        [
            measurement(id: "lo", source: .manual, value: 60),
            measurement(id: "mid", source: .manual, value: 80),
            measurement(id: "hi", source: .manual, value: 100)
        ]
    }

    @Test("nil min + nil max leaves the value-range filter inert")
    func valueRangeOpenEnded() {
        let result = MeasurementListFilter.apply(
            rangeItems(), source: nil, query: "", valueMin: nil, valueMax: nil
        )
        #expect(result.map(\.id) == ["lo", "mid", "hi"])
    }

    @Test("min bound drops rows below it (inclusive)")
    func valueRangeMin() {
        let result = MeasurementListFilter.apply(
            rangeItems(), source: nil, query: "", valueMin: 80, valueMax: nil
        )
        #expect(Set(result.map(\.id)) == Set(["mid", "hi"]))
    }

    @Test("max bound drops rows above it (inclusive)")
    func valueRangeMax() {
        let result = MeasurementListFilter.apply(
            rangeItems(), source: nil, query: "", valueMin: nil, valueMax: 80
        )
        #expect(Set(result.map(\.id)) == Set(["lo", "mid"]))
    }

    @Test("both bounds keep only the closed interval")
    func valueRangeBoth() {
        let result = MeasurementListFilter.apply(
            rangeItems(), source: nil, query: "", valueMin: 70, valueMax: 90
        )
        #expect(result.map(\.id) == ["mid"])
    }

    @Test("inverted min>max is normalised, not a zero-result trap")
    func valueRangeInverted() {
        let result = MeasurementListFilter.apply(
            rangeItems(), source: nil, query: "", valueMin: 90, valueMax: 70
        )
        #expect(result.map(\.id) == ["mid"])
    }

    @Test("value range composes with source chip and search needle")
    func valueRangeComposes() {
        let items: [Measurement] = [
            measurement(id: "a", source: .manual, note: "morning", value: 75),
            measurement(id: "b", source: .manual, note: "morning", value: 95),
            measurement(id: "c", source: .appleHealth, note: "morning", value: 75)
        ]
        let result = MeasurementListFilter.apply(
            items, source: .manual, query: "morning", valueMin: 70, valueMax: 80
        )
        #expect(result.map(\.id) == ["a"])
    }

    @Test("a non-finite value is excluded when a bound is active (NaN guard)")
    func valueRangeExcludesNonFinite() {
        let items: [Measurement] = [
            measurement(id: "ok", source: .manual, value: 80),
            measurement(id: "nan", source: .manual, value: Double.nan),
            measurement(id: "inf", source: .manual, value: Double.infinity)
        ]
        // Min bound active: NaN/inf compare false against the bound, so without
        // the guard they would slip through as if matching. Only the finite,
        // in-range row survives.
        #expect(
            MeasurementListFilter
                .applyValueRange(items, valueMin: 70, valueMax: nil)
                .map(\.id) == ["ok"]
        )
        // Max bound active: +inf must not be admitted either.
        #expect(
            MeasurementListFilter
                .applyValueRange(items, valueMin: nil, valueMax: 1000)
                .map(\.id) == ["ok"]
        )
        // With NO bound active the filter is inert and passes every row
        // through verbatim (non-finite included — nothing to compare against).
        #expect(
            MeasurementListFilter
                .applyValueRange(items, valueMin: nil, valueMax: nil)
                .count == 3
        )
    }

    @Test("BP rows filter on the systolic component")
    func valueRangeBloodPressure() {
        let bp = Measurement(
            id: "bp",
            kind: .bloodPressure,
            recordedAt: now,
            value: .bloodPressure(systolic: 130, diastolic: 85),
            source: .manual
        )
        #expect(
            MeasurementListFilter
                .applyValueRange([bp], valueMin: 120, valueMax: 140)
                .map(\.id) == ["bp"]
        )
        #expect(
            MeasurementListFilter
                .applyValueRange([bp], valueMin: 140, valueMax: nil)
                .isEmpty
        )
    }
}
