import Foundation
@testable import HealthLog
import Testing

/// **Build 3 / item 3.3 — the measurement-list date-range filter.**
///
/// iOS had no date filter on any surface; web has had `from` / `to` since
/// `measurement-list.tsx:328-329`. The predicate is pure so it can be pinned
/// without a SwiftUI render context, exactly like the value-range filter it
/// sits next to.
@Suite("Build 3 — measurement list date range")
struct MeasurementListDateRangeTests {
    private static var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        // Pin the zone so "start of day" is deterministic on any CI host.
        cal.timeZone = TimeZone(identifier: "Europe/Berlin") ?? .gmt
        return cal
    }

    private static func date(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: iso) ?? Date(timeIntervalSince1970: 0)
    }

    private static func row(_ id: String, at iso: String) -> HealthLog.Measurement {
        HealthLog.Measurement(
            id: id,
            kind: .weight,
            recordedAt: date(iso),
            value: .scalar(80),
            note: nil,
            source: .manual
        )
    }

    private static let rows: [HealthLog.Measurement] = [
        row("a", at: "2026-06-01T09:00:00+02:00"),
        row("b", at: "2026-06-15T09:00:00+02:00"),
        // Late on the boundary day — the case a naive `<= to` comparison hides.
        row("c", at: "2026-06-30T23:30:00+02:00"),
        row("d", at: "2026-07-10T09:00:00+02:00")
    ]

    @Test("no bounds is a passthrough")
    func noBoundsIsPassthrough() {
        let out = MeasurementListFilter.applyDateRange(Self.rows, from: nil, to: nil, calendar: Self.calendar)
        #expect(out.count == 4)
    }

    @Test("a lower bound keeps the whole starting day")
    func lowerBoundIncludesItsOwnDay() {
        // "from 15 June" must include a reading taken at 09:00 that morning,
        // not start counting from the instant the picker happened to produce.
        let out = MeasurementListFilter.applyDateRange(
            Self.rows,
            from: Self.date("2026-06-15T18:00:00+02:00"),
            to: nil,
            calendar: Self.calendar
        )
        #expect(out.map(\.id) == ["b", "c", "d"])
    }

    @Test("an upper bound keeps the whole ending day, including a late evening reading")
    func upperBoundIncludesItsOwnDay() {
        // The bug this pins: with a raw `<= to` comparison, "to 30 June" picked
        // at 08:00 would silently drop the 23:30 reading on that very day.
        let out = MeasurementListFilter.applyDateRange(
            Self.rows,
            from: nil,
            to: Self.date("2026-06-30T08:00:00+02:00"),
            calendar: Self.calendar
        )
        #expect(out.map(\.id) == ["a", "b", "c"])
    }

    @Test("both bounds compose into an inclusive window")
    func bothBoundsCompose() {
        let out = MeasurementListFilter.applyDateRange(
            Self.rows,
            from: Self.date("2026-06-15T12:00:00+02:00"),
            to: Self.date("2026-06-30T12:00:00+02:00"),
            calendar: Self.calendar
        )
        #expect(out.map(\.id) == ["b", "c"])
    }

    @Test("an inverted range is swapped rather than returning nothing")
    func invertedRangeIsSwapped() {
        // Mirrors `applyValueRange`: the operator must never be able to trap
        // themselves in an empty list by picking the bounds out of order.
        let out = MeasurementListFilter.applyDateRange(
            Self.rows,
            from: Self.date("2026-06-30T12:00:00+02:00"),
            to: Self.date("2026-06-15T12:00:00+02:00"),
            calendar: Self.calendar
        )
        #expect(out.map(\.id) == ["b", "c"])
    }

    @Test("the date range composes with source, value range and search")
    func composesWithTheOtherFilters() {
        let out = MeasurementListFilter.apply(
            Self.rows,
            source: .manual,
            query: "",
            valueMin: 70,
            valueMax: 90,
            dateFrom: Self.date("2026-06-15T00:00:00+02:00"),
            dateTo: Self.date("2026-06-30T00:00:00+02:00")
        )
        #expect(out.map(\.id) == ["b", "c"])
    }

    @Test("the computed source is offered as a filter chip")
    func computedSourceIsChippable() {
        // It was missing from the chip order list, so COMPUTED rows (the
        // screener sums since v1.27.6) could be searched by name but never
        // filtered — the label and the search alias existed, the chip did not.
        let computedRow = HealthLog.Measurement(
            id: "computed-1",
            kind: .weight,
            recordedAt: Self.date("2026-06-01T09:00:00+02:00"),
            value: .scalar(80),
            note: nil,
            source: .computed
        )
        let sources = MeasurementListFilter.availableSources(in: Self.rows + [computedRow])
        #expect(sources.contains(.computed), "a loaded COMPUTED row must surface its chip")
        #expect(sources.contains(.manual))
    }
}
