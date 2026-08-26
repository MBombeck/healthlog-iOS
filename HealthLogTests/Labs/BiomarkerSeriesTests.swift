import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// v0154 LR-REDO — locks the pure derivation helpers behind the Insights-class
/// biomarker detail page: the per-biomarker series filter, the range-window
/// filter, the on-device stats / median compute, and the explainer-lookup
/// (slug → string, with the `context` + empty fallbacks). All pure value math —
/// no store, no network.
@Suite("BiomarkerSeries + Explainer (v0154 LR-REDO)")
struct BiomarkerSeriesTests {
    // MARK: - Fixtures

    private func row(
        id: String,
        analyte: String,
        value: Double?,
        takenAt: String,
        biomarkerId: String? = nil,
        low: Double? = nil,
        high: Double? = nil,
        status: LabRangeStatus = .inRange,
        valueText: String? = nil
    ) -> LabResultDTO {
        LabResultDTO(
            id: id,
            biomarkerId: biomarkerId,
            panel: nil,
            analyte: analyte,
            value: value,
            valueText: valueText,
            unit: "U/L",
            referenceLow: low,
            referenceHigh: high,
            takenAt: takenAt,
            source: "MANUAL",
            hasNote: false,
            rangeStatus: status,
            createdAt: takenAt,
            updatedAt: takenAt
        )
    }

    /// ISO-8601 string `n` days before a fixed reference now.
    private static let now = ISO8601DateFormatter().date(from: "2026-06-22T12:00:00Z")!
    private func daysAgo(_ n: Int) -> String {
        let date = Calendar.current.date(byAdding: .day, value: -n, to: Self.now)!
        return ISO8601DateFormatter().string(from: date)
    }

    // MARK: - Per-biomarker series filter

    @Test("rows(forAnalyte:) filters to the analyte, newest-first, case-insensitive")
    func analyteFilter() {
        let labs = [
            row(id: "a", analyte: "GGT", value: 30, takenAt: daysAgo(1)),
            row(id: "b", analyte: "ALT", value: 20, takenAt: daysAgo(2)),
            row(id: "c", analyte: "ggt", value: 40, takenAt: daysAgo(3))
        ]
        let series = BiomarkerSeries.rows(forAnalyte: "GGT", in: labs)
        #expect(series.map(\.id) == ["a", "c"])
        // Newest-first.
        #expect(series.first?.id == "a")
    }

    @Test("rows(forAnalyte:) with a blank analyte matches nothing")
    func blankAnalyte() {
        let labs = [row(id: "a", analyte: "", value: 1, takenAt: daysAgo(1))]
        #expect(BiomarkerSeries.rows(forAnalyte: "", in: labs).isEmpty)
    }

    @Test("rows(forBiomarkerId:) filters by the linked id")
    func biomarkerIdFilter() {
        let labs = [
            row(id: "a", analyte: "GGT", value: 30, takenAt: daysAgo(1), biomarkerId: "bm-1"),
            row(id: "b", analyte: "GGT", value: 35, takenAt: daysAgo(2), biomarkerId: "bm-2")
        ]
        let series = BiomarkerSeries.rows(forBiomarkerId: "bm-1", in: labs)
        #expect(series.map(\.id) == ["a"])
    }

    // MARK: - Range-window filter

    @Test("windowed filters to the selected range, .all is a pass-through")
    func windowFilter() {
        let labs = [
            row(id: "today", analyte: "GGT", value: 30, takenAt: daysAgo(0)),
            row(id: "lastWeek", analyte: "GGT", value: 31, takenAt: daysAgo(5)),
            row(id: "lastMonth", analyte: "GGT", value: 32, takenAt: daysAgo(20)),
            row(id: "lastYear", analyte: "GGT", value: 33, takenAt: daysAgo(200))
        ]
        let week = BiomarkerSeries.windowed(labs, range: .week, now: Self.now)
        #expect(Set(week.map(\.id)) == ["today", "lastWeek"])

        let month = BiomarkerSeries.windowed(labs, range: .month, now: Self.now)
        #expect(Set(month.map(\.id)) == ["today", "lastWeek", "lastMonth"])

        let all = BiomarkerSeries.windowed(labs, range: .all, now: Self.now)
        #expect(all.count == 4)
    }

    // MARK: - Stats / median compute

    @Test("stats computes mean / min / max over the values")
    func statsCompute() throws {
        let labs = [
            row(id: "a", analyte: "GGT", value: 10, takenAt: daysAgo(1)),
            row(id: "b", analyte: "GGT", value: 20, takenAt: daysAgo(2)),
            row(id: "c", analyte: "GGT", value: 30, takenAt: daysAgo(3))
        ]
        let stats = try #require(BiomarkerSeries.stats(for: labs))
        #expect(stats.min == 10)
        #expect(stats.max == 30)
        #expect(stats.mean == 20)
        #expect(stats.count == 3)
    }

    @Test("stats returns nil for an empty set")
    func statsEmpty() {
        #expect(BiomarkerSeries.stats(for: []) == nil)
    }

    @Test("median is the middle value (odd) / average of two middles (even)")
    func medianCompute() {
        let odd = [
            row(id: "a", analyte: "GGT", value: 10, takenAt: daysAgo(1)),
            row(id: "b", analyte: "GGT", value: 50, takenAt: daysAgo(2)),
            row(id: "c", analyte: "GGT", value: 20, takenAt: daysAgo(3))
        ]
        #expect(BiomarkerSeries.median(for: odd) == 20)

        let even = odd + [row(id: "d", analyte: "GGT", value: 30, takenAt: daysAgo(4))]
        // Sorted: 10,20,30,50 → (20+30)/2 = 25.
        #expect(BiomarkerSeries.median(for: even) == 25)

        #expect(BiomarkerSeries.median(for: []) == nil)
    }

    // MARK: - Absent-value contamination (MED-1)

    @Test("stats / median ignore valueIsAbsent rows (phantom 0 sentinel)")
    func absentRowsExcludedFromStatsAndMedian() throws {
        // The absent row's value is the server sentinel 0 (key omitted on the
        // wire), NOT a real reading — it must not drag min to 0 or skew the mean.
        let labs = [
            row(id: "a", analyte: "GGT", value: 10, takenAt: daysAgo(1)),
            row(id: "absent", analyte: "GGT", value: nil, takenAt: daysAgo(2)),
            row(id: "b", analyte: "GGT", value: 20, takenAt: daysAgo(3)),
            row(id: "c", analyte: "GGT", value: 30, takenAt: daysAgo(4))
        ]
        let stats = try #require(BiomarkerSeries.stats(for: labs))
        #expect(stats.min == 10) // not 0
        #expect(stats.max == 30)
        #expect(stats.mean == 20) // (10+20+30)/3, absent excluded
        #expect(stats.count == 3) // absent row not counted
        // Median over [10,20,30] = 20, not the phantom-0-shifted 15.
        #expect(BiomarkerSeries.median(for: labs) == 20)
    }

    @Test("valueBearing drops only the absent rows, keeps real readings")
    func valueBearingFilter() {
        let labs = [
            row(id: "a", analyte: "GGT", value: 5, takenAt: daysAgo(1)),
            row(id: "absent", analyte: "GGT", value: nil, takenAt: daysAgo(2)),
            row(id: "zero", analyte: "GGT", value: 0, takenAt: daysAgo(3)) // genuine 0, kept
        ]
        let bearing = BiomarkerSeries.valueBearing(labs)
        #expect(Set(bearing.map(\.id)) == ["a", "zero"])
    }

    // MARK: - Explainer lookup

    @Test("explainer prefers the user-entered context over the catalogue")
    func explainerContextWins() {
        let text = BiomarkerExplainer.text(context: "My own note", name: "GGT")
        #expect(text == "My own note")
    }

    @Test("explainer falls back to the catalogue auto-text by name / alias")
    func explainerCatalogueFallback() throws {
        // Exact catalogue name resolves a non-empty, non-key explainer
        // (locale-agnostic — the localized copy varies by run language).
        let ggt = try #require(BiomarkerExplainer.text(context: nil, name: "GGT"))
        #expect(!ggt.isEmpty)
        #expect(ggt != "biomarker.explainer.ggt")
        #expect(BiomarkerExplainer.slug(forName: "GGT") == "ggt")
        // German alias resolves the same slug.
        let chol = BiomarkerExplainer.catalogExplainer(forName: "Cholesterin")
        #expect(chol != nil)
        // Diacritic-insensitive alias.
        #expect(BiomarkerExplainer.slug(forName: "Folsaeure") == "folate")
    }

    @Test("explainer hides (nil) for an unknown free-text analyte with no context")
    func explainerEmptyFallback() {
        #expect(BiomarkerExplainer.text(context: nil, name: "Some Custom Analyte") == nil)
        #expect(BiomarkerExplainer.text(context: "   ", name: "Some Custom Analyte") == nil)
    }

    @Test("every catalogue slug resolves to a non-empty, non-key explainer string")
    func everySlugHasExplainer() {
        for slug in BiomarkerExplainer.knownSlugs {
            let key = "biomarker.explainer.\(slug)"
            let value = String(localized: String.LocalizationValue(key))
            #expect(value != key, "missing explainer string for \(slug)")
            #expect(!value.isEmpty)
        }
    }
}

// swiftlint:enable force_unwrapping
