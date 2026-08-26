import Foundation

/// **Pure mapping logic for the cycle home (`CycleScreen`).**
///
/// All the load-bearing "turn the server's answer into renderable shapes" logic
/// lives here as `nonisolated static` pure functions so it is unit-testable
/// without a SwiftUI host (`CycleScreenModelTests`) and carries no view state.
///
/// **Z1 (#72) — this file no longer decides anything.** Until v1.35.2 it scanned
/// the calendar's per-day phase labels for menstrual runs to derive the current
/// cycle window, counted the day of cycle itself, collapsed the days into
/// segments, substituted a population-default ring when the data looked sparse,
/// and compared today against the prediction band to call a period "later than
/// usual". Every one of those was a second opinion about a person's body, formed
/// on a device that does not necessarily know which day it is in that person's
/// profile timezone. The server now publishes the resolved verdict
/// (``CycleVerdictDTO``: `state`, `phase`, `spans`, `cycleLength`, `dayOfCycle`,
/// `overdueDays`) and this type only draws it.
///
/// What is left here is arithmetic with no judgement in it: fractions → arc day
/// ranges, and a date → its 1-based day index inside the drawn cycle.
public enum CycleScreenModel {
    // MARK: - Ring model

    /// Build the hero ring from the SERVER's verdict. `nil` when the verdict has
    /// nothing to draw (`INSUFFICIENT_DATA` carries empty `spans`) — the caller
    /// then shows the honest learning surface rather than an empty circle.
    ///
    /// - `cycleLengthDays` / `segments` come from `cycleLength` + `spans`, which
    ///   the server cuts to the OBSERVED run (or, for a low-data tracker, to the
    ///   profile's idealized proportions — that decision is the server's too).
    /// - The day marker is drawn only where `dayOfCycle` exists. In `OVERDUE`
    ///   the server deliberately sends `null`: past the typical length plus its
    ///   grace the count is no longer an observed fact, so the ring draws its
    ///   arcs without claiming a position on them.
    /// - The fertile band and the ovulation marker are drawn only in `IN_CYCLE`.
    ///   In `OVERDUE` the arcs are an idealized template detached from the real
    ///   elapsed run, and pinning a fertility claim onto it would be an
    ///   invention.
    public nonisolated static func ringModel(
        verdict: CycleVerdictDTO,
        prediction: CyclePredictionDTO?,
        centerTitle: String,
        centerSubtitle: String,
        suppressFertility: Bool = false
    ) -> HLCycleRing.Model? {
        guard let length = verdict.cycleLength, length > 0 else { return nil }
        let arcs = segments(verdict.spans, cycleLength: length)
        guard !arcs.isEmpty else { return nil }

        let inCycle = verdict.stateValue == .inCycle
        let showsFertility = inCycle && !suppressFertility
        let fertile = showsFertility
            ? dayRange(
                from: verdict.fertileWindow.start,
                to: verdict.fertileWindow.end,
                cycleStart: verdict.cycleStartDate,
                cycleLength: length
            )
            : nil
        let ovulation = showsFertility
            ? dayIndex(
                for: prediction?.predictedOvulation,
                cycleStart: verdict.cycleStartDate,
                cycleLength: length
            )
            : nil

        return HLCycleRing.Model(
            cycleLengthDays: length,
            dayOfCycle: verdict.dayOfCycle ?? 1,
            showsDayMarker: verdict.dayOfCycle != nil,
            segments: arcs,
            predictedOvulationDay: ovulation,
            fertileWindow: fertile,
            centerTitle: centerTitle,
            centerSubtitle: centerSubtitle
        )
    }

    /// Today's phase — read off the verdict, never derived. `nil` is a real
    /// answer: in `OVERDUE` and `INSUFFICIENT_DATA` the server states that it
    /// does not know, and so does the app.
    public nonisolated static func phase(_ verdict: CycleVerdictDTO?) -> CyclePhasePalette.Phase? {
        verdict?.phaseValue.map(palettephase)
    }

    // MARK: - Centre copy

    /// **Z1 (#72) — in `OVERDUE` the centre carries `overdueDays`, not a cycle
    /// day.** The two are different statements and the copy says which one it
    /// is: "12 Tage überfällig" is not "Tag 12". The server nulls `dayOfCycle`
    /// there on purpose — the likeliest reason a cycle runs long is that a new
    /// one already began and was never logged, so "day 71" would be counting
    /// something that does not exist. `overdueDays` measures against the usual
    /// length, not against usual length plus the server's tolerance: someone
    /// asking how late they are means their own cycle, not our grace window.
    public nonisolated static func centerTitle(verdict: CycleVerdictDTO, hasPrediction: Bool) -> String {
        if verdict.stateValue == .overdue {
            guard let days = verdict.overdueDays else {
                return String(localized: "cycle.home.center.late.title")
            }
            return String(format: String(localized: "cycle.home.center.overdue.title"), days)
        }
        guard let until = verdict.daysUntilNext else {
            // `daysUntilNext` is null both when no forecast ran and once the
            // predicted start has passed. A forecast on file means the latter.
            return String(
                localized: hasPrediction ? "cycle.home.center.dueWindow" : "cycle.home.center.learning.title"
            )
        }
        if until == 0 { return String(localized: "cycle.home.center.dueToday") }
        return String(format: String(localized: "cycle.home.center.inDays"), until)
    }

    public nonisolated static func centerSubtitle(verdict: CycleVerdictDTO) -> String {
        if verdict.stateValue == .overdue {
            // `cycleStartDate` stays set while overdue — the last logged period
            // start remains a fact once the count stops, and it is the ground
            // the number above is measured from.
            guard let start = verdict.cycleStartDate, let date = dayKeyFormatter.date(from: start) else {
                return String(localized: "cycle.home.center.overdue.subtitle.noStart")
            }
            return String(
                format: String(localized: "cycle.home.center.overdue.subtitle"),
                shortDayFormatter.string(from: date)
            )
        }
        guard let day = verdict.dayOfCycle else {
            return String(localized: "cycle.home.center.learning.subtitle")
        }
        return String(format: String(localized: "cycle.home.center.cycleDay"), day)
    }

    /// `YYYY-MM-DD` day keys, POSIX + device zone (the same pair `CycleScreen`
    /// uses for the calendar grid).
    static let dayKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Day + month only — a cycle start is a date, not a timestamp.
    static let shortDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = .current
        f.setLocalizedDateFormatFromTemplate("ddMMM")
        return f
    }()

    // MARK: - Arithmetic (no judgement below this line)

    /// `spans` (fractions summing to ~1) → contiguous 1-based day ranges tiling
    /// `1...cycleLength`.
    ///
    /// Boundaries are placed from the CUMULATIVE fraction, so rounding cannot
    /// accumulate and the last arc always ends exactly on `cycleLength`. A span
    /// that rounds to zero days is dropped rather than widened, and a span whose
    /// phase string is unknown advances the cursor without painting: the arc
    /// stays bare track instead of being mislabelled with its neighbour's hue.
    nonisolated static func segments(
        _ spans: [CyclePhaseSpanDTO],
        cycleLength: Int
    ) -> [HLCycleRing.Model.Segment] {
        guard cycleLength > 0, !spans.isEmpty else { return [] }
        let total = spans.reduce(0.0) { $0 + max(0, $1.fraction) }
        guard total > 0 else { return [] }

        var result: [HLCycleRing.Model.Segment] = []
        var cursor = 0
        var accumulated = 0.0
        for (index, span) in spans.enumerated() {
            accumulated += max(0, span.fraction) / total
            let isLast = index == spans.count - 1
            let boundary = isLast
                ? cycleLength
                : min(cycleLength, Int((accumulated * Double(cycleLength)).rounded()))
            guard boundary > cursor else { continue }
            if let phase = span.phaseValue.map(palettephase) {
                result.append(.init(phase: phase, dayRange: (cursor + 1) ... boundary))
            }
            cursor = boundary
        }
        return result
    }

    /// A `YYYY-MM-DD` date → its 1-based day index inside the drawn cycle, or
    /// `nil` when the date is missing or falls outside `1...cycleLength`.
    nonisolated static func dayIndex(
        for date: String?,
        cycleStart: String?,
        cycleLength: Int
    ) -> Int? {
        guard let date, !date.isEmpty, let cycleStart, !cycleStart.isEmpty else { return nil }
        let index = CyclePredictionEngine.dayDiff(date, cycleStart) + 1
        guard (1 ... max(1, cycleLength)).contains(index) else { return nil }
        return index
    }

    /// A date pair → the inclusive day range inside the drawn cycle. Ends that
    /// fall outside the ring are clamped to it; a pair with no usable end at all
    /// yields `nil` rather than a guessed band.
    nonisolated static func dayRange(
        from start: String?,
        to end: String?,
        cycleStart: String?,
        cycleLength: Int
    ) -> ClosedRange<Int>? {
        guard let cycleStart, !cycleStart.isEmpty, cycleLength > 0 else { return nil }
        guard let start, !start.isEmpty, let end, !end.isEmpty else { return nil }
        let rawLow = CyclePredictionEngine.dayDiff(start, cycleStart) + 1
        let rawHigh = CyclePredictionEngine.dayDiff(end, cycleStart) + 1
        guard rawHigh >= 1, rawLow <= cycleLength, rawLow <= rawHigh else { return nil }
        return max(1, rawLow) ... min(cycleLength, rawHigh)
    }

    /// Engine phase → palette phase (single mapping table).
    nonisolated static func palettephase(_ phase: CyclePhaseValue) -> CyclePhasePalette.Phase {
        switch phase {
        case .menstrual: .menstrual
        case .follicular: .follicular
        case .ovulatory: .ovulatory
        case .luteal: .luteal
        }
    }
}
