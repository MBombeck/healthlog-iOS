import Foundation

/// v0.10.0 W-Mood-A — the FULL gated correlation engine.
///
/// Ports MoodLog's `computeCorrelations` (`statistics-compute.ts` L263-736):
/// the standout feature that encodes the operator's own definition of a useful
/// mood insight. Each detector is **sample-gated** with the exact min-sample +
/// min-delta thresholds from the oracle; a card self-suppresses when the data
/// can't support it, so depth appears when the data is rich and zero clutter
/// when it isn't (W-MOOD-BRIEF EXPANDED scope — full engine, gating is the
/// restraint mechanism). The whole `MoodPatternSection` is omitted by the host
/// when this returns `[]`.
///
/// Sentences are pre-resolved + localized here (de/en via `Localizable.xcstrings`,
/// source = en) so the view layer stays presentation-only. Numbers format with
/// the locale decimal separator at one fractional digit.
///
/// Detectors (oracle parity): previous-day carry-over · weekend-vs-weekday ·
/// best/worst weekday · tag → same-day mood (best + worst) · note-presence →
/// mood · lagged-tag (yesterday → today) · multi-entry-day.
enum MoodPatternDetector {
    /// Engine requires ≥ 5 entries (oracle L264) before surfacing any pattern.
    static let minEntries = 5

    /// One tag's mean mood + delta-vs-baseline, ranked by |delta|. Internal to
    /// the tag + lagged-tag detectors (avoids a 3-member tuple).
    private struct TagCorrelation {
        let tag: String
        let avg: Double
        let diff: Double
    }

    static func detect(
        entries: [MoodEntry],
        daily: [MoodDailyAverage],
        calendar: Calendar
    ) -> [MoodPattern] {
        guard entries.count >= minEntries else { return [] }

        // date(startOfDay) → mean score, and the per-day tag set / per-entry
        // accessors the detectors need. `daily` already carries the per-day
        // mean; build the lookup maps once.
        let dayScore: [Date: Double] = Dictionary(
            uniqueKeysWithValues: daily.map { ($0.day, $0.average) }
        )
        let sortedDays = daily.map(\.day) // ascending
        let overall = daily.isEmpty ? 0 : daily.map(\.average).reduce(0, +) / Double(daily.count)

        var results: [MoodPattern] = []

        if let p = previousDay(sortedDays: sortedDays, dayScore: dayScore, calendar: calendar) {
            results.append(p)
        }
        if let p = weekend(daily: daily, calendar: calendar) {
            results.append(p)
        }
        if let p = bestWeekday(daily: daily, calendar: calendar) {
            results.append(p)
        }
        results.append(contentsOf: tagSameDay(entries: entries))
        if let p = notePresence(entries: entries) {
            results.append(p)
        }
        results.append(contentsOf: laggedTag(
            entries: entries,
            sortedDays: sortedDays,
            dayScore: dayScore,
            overall: overall,
            calendar: calendar
        ))
        if let p = multiEntry(entries: entries, dayScore: dayScore, calendar: calendar) {
            results.append(p)
        }

        return results
    }

    // MARK: - 1. Previous-day carry-over (oracle L304-346)

    private static func previousDay(
        sortedDays: [Date],
        dayScore: [Date: Double],
        calendar: Calendar
    ) -> MoodPattern? {
        var sameDir = 0
        var pairs = 0
        for i in 1 ..< max(sortedDays.count, 1) {
            let prev = sortedDays[i - 1]
            let curr = sortedDays[i]
            guard calendar.dateComponents([.day], from: prev, to: curr).day == 1 else { continue }
            pairs += 1
            let prevScore = dayScore[prev] ?? 3
            let currScore = dayScore[curr] ?? 3
            if (prevScore >= 4 && currScore >= 4) || (prevScore <= 2 && currScore <= 2) {
                sameDir += 1
            }
        }
        guard pairs >= 3 else { return nil }
        let ratio = Double(sameDir) / Double(pairs)
        let pct = Int((ratio * 100).rounded())
        if ratio > 0.6 {
            return MoodPattern(
                id: "prev-day",
                kind: .previousDay,
                strength: ratio > 0.75 ? .strong : .moderate,
                direction: .neutral,
                sentence: String(localized: "Your mood usually carries over — \(pct)% of the time the next day stays similar."),
                icon: "repeat"
            )
        } else if ratio < 0.3, pairs >= 5 {
            return MoodPattern(
                id: "prev-day",
                kind: .previousDay,
                strength: .moderate,
                direction: .neutral,
                sentence: String(localized: "Your mood often shifts day to day — only \(pct)% of days stay similar."),
                icon: "repeat"
            )
        }
        return nil
    }

    // MARK: - 2. Weekend vs weekday (oracle L348-387)

    private static func weekend(daily: [MoodDailyAverage], calendar: Calendar) -> MoodPattern? {
        var weekday: [Double] = []
        var weekend: [Double] = []
        for avg in daily {
            let dow = calendar.component(.weekday, from: avg.day) // 1=Sun…7=Sat
            if dow == 1 || dow == 7 {
                weekend.append(avg.average)
            } else {
                weekday.append(avg.average)
            }
        }
        guard weekday.count >= 3, weekend.count >= 2 else { return nil }
        let weekdayAvg = weekday.reduce(0, +) / Double(weekday.count)
        let weekendAvg = weekend.reduce(0, +) / Double(weekend.count)
        let diff = weekendAvg - weekdayAvg
        guard abs(diff) >= 0.3 else { return nil }
        let strength: MoodPattern.Strength = abs(diff) >= 0.7 ? .strong : .moderate
        let sentence = if diff > 0 {
            String(localized: "You feel better on weekends — averaging \(fmt(weekendAvg)) versus \(fmt(weekdayAvg)) on weekdays.")
        } else {
            String(localized: "You feel better on weekdays — averaging \(fmt(weekdayAvg)) versus \(fmt(weekendAvg)) on weekends.")
        }
        return MoodPattern(
            id: "weekend",
            kind: .weekend,
            strength: strength,
            direction: diff > 0 ? .positive : .negative,
            sentence: sentence,
            icon: "calendar"
        )
    }

    // MARK: - 3. Best/worst weekday (oracle L389-423)

    private static func bestWeekday(daily: [MoodDailyAverage], calendar: Calendar) -> MoodPattern? {
        // Bucket by weekday (1=Sun…7=Sat).
        var buckets: [Int: [Double]] = [:]
        for avg in daily {
            let dow = calendar.component(.weekday, from: avg.day)
            buckets[dow, default: []].append(avg.average)
        }
        let valid = buckets.filter { $0.value.count >= 2 }
        guard valid.count >= 3 else { return nil }
        let dayAvgs = valid.mapValues { $0.reduce(0, +) / Double($0.count) }
        // 09-04 — deterministic tie-break. `Dictionary` iteration order is
        // randomised per process, so `max(by:)`/`min(by:)` over two weekdays
        // with the SAME average named a different day on each evaluation: the
        // identical history reported "best on Monday" in one render and "best
        // on Wednesday" in the next, and — before the analysis was memoized —
        // could report both at once, because the hero and the heatmap computed
        // the insight set separately. Ties now resolve to the earliest weekday.
        let ranked = dayAvgs.sorted { lhs, rhs in
            lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
        }
        guard let best = ranked.first, let worst = ranked.last else { return nil }
        guard best.value - worst.value >= 0.3 else { return nil }
        let bestName = weekdayName(best.key, calendar: calendar)
        return MoodPattern(
            id: "best-day",
            kind: .bestWeekday,
            strength: (best.value - worst.value) >= 0.7 ? .strong : .moderate,
            direction: .positive,
            sentence: String(
                localized: "You feel best on \(bestName) — averaging \(fmt(best.value)) versus \(fmt(worst.value)) on your lowest day."
            ),
            icon: "sun.max"
        )
    }

    // MARK: - 4. Tag → same-day mood (oracle L425-512, best + worst)

    private static func tagSameDay(entries: [MoodEntry]) -> [MoodPattern] {
        let overall = Double(entries.map(\.score).reduce(0, +)) / Double(entries.count)
        var buckets: [String: [Int]] = [:]
        for entry in entries {
            for tag in entry.tags where !tag.hasPrefix("note:") {
                buckets[tag, default: []].append(entry.score)
            }
        }
        var correlations: [TagCorrelation] = []
        for (tag, scores) in buckets where scores.count >= 3 {
            let avg = Double(scores.reduce(0, +)) / Double(scores.count)
            let diff = avg - overall
            if abs(diff) >= 0.3 { correlations.append(TagCorrelation(tag: tag, avg: avg, diff: diff)) }
        }
        // Same reason as `bestWeekday`: the buckets come out of a `Dictionary`
        // and `sort` is not stable, so two tags with an equal |diff| swapped
        // places between evaluations. The tag name is the final, total key.
        correlations.sort { lhs, rhs in
            abs(lhs.diff) == abs(rhs.diff) ? lhs.tag < rhs.tag : abs(lhs.diff) > abs(rhs.diff)
        }

        var out: [MoodPattern] = []
        if let best = correlations.first(where: { $0.diff > 0 }) {
            out.append(MoodPattern(
                id: "tag-positive",
                kind: .tagPositive,
                strength: best.diff >= 0.7 ? .strong : .moderate,
                direction: .positive,
                sentence: String(
                    localized: "“\(best.tag)” days run higher — averaging \(fmt(best.avg)) versus your baseline of \(fmt(overall))."
                ),
                icon: "arrow.up.right"
            ))
        }
        if let worst = correlations.first(where: { $0.diff < 0 }) {
            out.append(MoodPattern(
                id: "tag-negative",
                kind: .tagNegative,
                strength: abs(worst.diff) >= 0.7 ? .strong : .moderate,
                direction: .negative,
                sentence: String(
                    localized: "“\(worst.tag)” days run lower — averaging \(fmt(worst.avg)) versus your baseline of \(fmt(overall))."
                ),
                icon: "arrow.down.right"
            ))
        }
        return out
    }

    // MARK: - 5. Note-presence → mood (oracle L514-551)

    private static func notePresence(entries: [MoodEntry]) -> MoodPattern? {
        var withNote: [Int] = []
        var withoutNote: [Int] = []
        for entry in entries {
            if let note = entry.note, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                withNote.append(entry.score)
            } else {
                withoutNote.append(entry.score)
            }
        }
        guard withNote.count >= 3, withoutNote.count >= 3 else { return nil }
        let noteAvg = Double(withNote.reduce(0, +)) / Double(withNote.count)
        let noNoteAvg = Double(withoutNote.reduce(0, +)) / Double(withoutNote.count)
        let diff = noteAvg - noNoteAvg
        guard abs(diff) >= 0.2 else { return nil }
        let sentence = if diff < 0 {
            String(localized: "You tend to write notes when feeling lower — \(fmt(noteAvg)) with a note versus \(fmt(noNoteAvg)) without.")
        } else {
            String(localized: "You tend to write notes when feeling higher — \(fmt(noteAvg)) with a note versus \(fmt(noNoteAvg)) without.")
        }
        return MoodPattern(
            id: "notes",
            kind: .notePresence,
            strength: abs(diff) >= 0.5 ? .strong : .moderate,
            direction: diff > 0 ? .positive : .negative,
            sentence: sentence,
            icon: "square.and.pencil"
        )
    }

    // MARK: - 6. Lagged-tag (yesterday → today, oracle L553-630)

    private static func laggedTag(
        entries: [MoodEntry],
        sortedDays: [Date],
        dayScore: [Date: Double],
        overall: Double,
        calendar: Calendar
    ) -> [MoodPattern] {
        // Per-day tag set.
        var dayTags: [Date: Set<String>] = [:]
        for entry in entries {
            let day = calendar.startOfDay(for: entry.recordedAt)
            for tag in entry.tags where !tag.hasPrefix("note:") {
                dayTags[day, default: []].insert(tag)
            }
        }
        var effects: [String: [Double]] = [:]
        for i in 1 ..< max(sortedDays.count, 1) {
            let prev = sortedDays[i - 1]
            let curr = sortedDays[i]
            guard calendar.dateComponents([.day], from: prev, to: curr).day == 1 else { continue }
            let todayScore = dayScore[curr] ?? 3
            for tag in dayTags[prev] ?? [] {
                effects[tag, default: []].append(todayScore)
            }
        }
        var correlations: [TagCorrelation] = []
        for (tag, scores) in effects where scores.count >= 3 {
            let avg = scores.reduce(0, +) / Double(scores.count)
            let diff = avg - overall
            if abs(diff) >= 0.3 { correlations.append(TagCorrelation(tag: tag, avg: avg, diff: diff)) }
        }
        // Same reason as `bestWeekday`: the buckets come out of a `Dictionary`
        // and `sort` is not stable, so two tags with an equal |diff| swapped
        // places between evaluations. The tag name is the final, total key.
        correlations.sort { lhs, rhs in
            abs(lhs.diff) == abs(rhs.diff) ? lhs.tag < rhs.tag : abs(lhs.diff) > abs(rhs.diff)
        }

        var out: [MoodPattern] = []
        if let best = correlations.first(where: { $0.diff > 0 }) {
            out.append(MoodPattern(
                id: "lag-tag-pos",
                kind: .laggedTag,
                strength: abs(best.diff) >= 0.7 ? .strong : .moderate,
                direction: .positive,
                sentence: String(
                    localized: "The day after “\(best.tag)” tends to be better — averaging \(fmt(best.avg)) versus your baseline of \(fmt(overall))."
                ),
                icon: "arrow.right"
            ))
        }
        if let worst = correlations.first(where: { $0.diff < 0 }) {
            out.append(MoodPattern(
                id: "lag-tag-neg",
                kind: .laggedTag,
                strength: abs(worst.diff) >= 0.7 ? .strong : .moderate,
                direction: .negative,
                sentence: String(
                    localized: "The day after “\(worst.tag)” tends to be lower — averaging \(fmt(worst.avg)) versus your baseline of \(fmt(overall))."
                ),
                icon: "arrow.right"
            ))
        }
        return out
    }

    // MARK: - 7. Multi-entry day → mood (oracle L632-675)

    private static func multiEntry(
        entries: [MoodEntry],
        dayScore: [Date: Double],
        calendar: Calendar
    ) -> MoodPattern? {
        var entriesPerDay: [Date: Int] = [:]
        for entry in entries {
            let day = calendar.startOfDay(for: entry.recordedAt)
            entriesPerDay[day, default: 0] += 1
        }
        var single: [Double] = []
        var multi: [Double] = []
        for (day, count) in entriesPerDay {
            let score = dayScore[day] ?? 3
            if count == 1 { single.append(score) } else { multi.append(score) }
        }
        guard multi.count >= 3, single.count >= 3 else { return nil }
        let singleAvg = single.reduce(0, +) / Double(single.count)
        let multiAvg = multi.reduce(0, +) / Double(multi.count)
        let diff = multiAvg - singleAvg
        guard abs(diff) >= 0.3 else { return nil }
        let sentence = if diff > 0 {
            String(
                localized: "Days with more check-ins run higher — averaging \(fmt(multiAvg)) versus \(fmt(singleAvg)) on single-entry days."
            )
        } else {
            String(
                localized: "You check in more on harder days — averaging \(fmt(multiAvg)) versus \(fmt(singleAvg)) on single-entry days."
            )
        }
        return MoodPattern(
            id: "multi-entries",
            kind: .multiEntry,
            strength: abs(diff) >= 0.5 ? .strong : .moderate,
            direction: diff > 0 ? .positive : .negative,
            sentence: sentence,
            icon: "number"
        )
    }

    // MARK: - Helpers

    /// One-fractional-digit, locale-decimal-separated number for sentence
    /// interpolation (matches the oracle's `toFixed(1)`).
    private static func fmt(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1)))
    }

    /// Localized full weekday name for the 1=Sun…7=Sat index.
    private static func weekdayName(_ weekday: Int, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        let symbols = formatter.weekdaySymbols ?? []
        let index = weekday - 1
        guard index >= 0, index < symbols.count else { return "" }
        return symbols[index]
    }
}
