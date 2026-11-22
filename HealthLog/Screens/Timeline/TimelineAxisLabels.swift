import SwiftUI
import UIKit

/// One name on the time axis: the day its step starts, where its line
/// stands and the text right of the line.
struct TimelineAxisLabel: Equatable, Sendable {
    let day: Int
    let x: CGFloat
    let text: String
}

/// Which names the time axis shows, as a pure function of window, width and
/// the measured width of each text.
///
/// The rule: a name never touches another, "Heute" or an edge. On month and
/// quarter steps January is named by its year alone ("2026" instead of
/// "Jan. 2026", which ran into the next month), and years are placed first
/// so the year context always stands. Only the first name may carry its
/// year beside the month, and only where that fits.
enum TimelineAxisLabels {
    /// Room kept free between two names, and between a name and "Heute".
    static let gap: CGFloat = HLSpace.sm
    /// A name starts this far right of its grid line.
    static let lineInset: CGFloat = HLSpace.xs

    /// The text of a name. `withYear` adds the year to a month on the first name.
    static func text(
        _ day: Int,
        step: TimelineAxisStep,
        withYear: Bool,
        today: Int,
        locale: Locale = .current
    ) -> String {
        let date = TimelineDay.date(day)
        switch step {
        case .day, .week:
            return HLDateFormat.dayMonth(date, relativeTo: TimelineDay.date(today), locale: locale)
        case .month, .quarter:
            if TimelineDay.components(day).month == 1 { return HLDateFormat.year(date, locale: locale) }
            return HLDateFormat.month(date, abbreviated: true, withYear: withYear, locale: locale)
        case .year:
            return HLDateFormat.year(date, locale: locale)
        }
    }

    /// Where "Heute" stands: centred on the today line, near the plot's end
    /// ending at it. `nil` when today lies outside the window.
    static func todaySpan(window: TimelineWindow, today: Int, width: CGFloat, todayWidth: CGFloat) -> ClosedRange<CGFloat>? {
        guard window.contains(today) else { return nil }
        let line = CGFloat(window.fraction(Double(today + 1))) * width
        let left = line + todayWidth / 2 > width ? line - todayWidth : line - todayWidth / 2
        return left ... left + todayWidth
    }

    /// The names that fit, left to right.
    static func labels(
        window: TimelineWindow,
        today: Int,
        width: CGFloat,
        leadingInset: CGFloat = 0,
        todayWidth: CGFloat,
        locale: Locale = .current,
        measure: (String) -> CGFloat
    ) -> [TimelineAxisLabel] {
        guard width > 0 else { return [] }
        let step = TimelineAxisStep.step(window: window, width: width)
        let x = { (day: Int) in CGFloat(window.fraction(Double(day))) * width }
        let starts = step.starts(in: window).filter { x($0) >= leadingInset }
        var taken: [ClosedRange<CGFloat>] = []
        if let today = todaySpan(window: window, today: today, width: width, todayWidth: todayWidth) { taken.append(today) }
        var placed: [TimelineAxisLabel] = []

        func place(_ day: Int, options: [String]) {
            let left = x(day) + lineInset
            for option in options {
                let span = left ... left + measure(option)
                let free = span.upperBound <= width
                    && taken.allSatisfy { span.lowerBound >= $0.upperBound + gap || span.upperBound + gap <= $0.lowerBound }
                guard free else { continue }
                taken.append(span)
                placed.append(TimelineAxisLabel(day: day, x: x(day), text: option))
                return
            }
        }

        let namesYears = step == .month || step == .quarter
        let isYear = { (day: Int) in namesYears && TimelineDay.components(day).month == 1 }
        for day in starts where isYear(day) {
            place(day, options: [text(day, step: step, withYear: false, today: today, locale: locale)])
        }
        for (index, day) in starts.enumerated() where !isYear(day) {
            let plain = text(day, step: step, withYear: false, today: today, locale: locale)
            let options = index == 0 && namesYears
                ? [text(day, step: step, withYear: true, today: today, locale: locale), plain]
                : [plain]
            place(day, options: options)
        }
        return placed.sorted { $0.day < $1.day }
    }

    /// Measures a text the way a text role draws it at a Dynamic Type size.
    static func measurer(
        _ style: UIFont.TextStyle,
        weight: UIFont.Weight,
        typeSize: DynamicTypeSize
    ) -> (String) -> CGFloat {
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(typeSize))
        let size = UIFont.preferredFont(forTextStyle: style, compatibleWith: traits).pointSize
        let font = UIFont.systemFont(ofSize: size, weight: weight)
        return { ceil(($0 as NSString).size(withAttributes: [.font: font]).width) }
    }
}

/// One name placed on a lane row: where it starts, how wide it may be and
/// what it says.
struct TimelineRowLabel: Equatable, Sendable {
    let id: String
    let x: CGFloat
    let width: CGFloat
    let text: String
    /// A mark's name (above its dot) rather than a bar's.
    let isMark: Bool
}

/// Which names a lane row shows, as a pure function of the measured texts.
///
/// A name is shown whole or not at all, so a row never fills with "Mag…",
/// "Ome…", "Hau…". The row's own name (a medication on its first piece)
/// goes first and may run on over the pieces after it, whose doses then give
/// way; where even that is too long it shortens to the name alone, and only
/// a name of a row may stand cut, from ``minimumCut`` on. A mark near the
/// end of the row ends at its dot when there is no room after it.
enum TimelineRowLabels {
    struct Candidate: Equatable, Sendable {
        let id: String
        /// Where the text starts when it stands after its bar's start or its dot.
        let anchor: CGFloat
        let text: String
        /// A shorter form tried when the text does not fit (the medication's name alone).
        var short: String?
        /// The name of the row; placed first.
        var isRowName = false
        var isMark = false
        /// For a mark: where a text placed before the dot ends.
        var endAnchor: CGFloat?
    }

    static let gap: CGFloat = HLSpace.xs
    /// The narrowest a cut row name stands; below it shows nothing.
    static let minimumCut: CGFloat = 56

    static func place(
        _ candidates: [Candidate],
        width: CGFloat,
        leadingInset: CGFloat = 0,
        measure: (String) -> CGFloat
    ) -> [TimelineRowLabel] {
        var taken: [ClosedRange<CGFloat>] = []
        var placed: [TimelineRowLabel] = []
        let free = { (span: ClosedRange<CGFloat>) in
            span.lowerBound >= leadingInset && span.upperBound <= width
                && taken.allSatisfy { span.lowerBound >= $0.upperBound + gap || span.upperBound + gap <= $0.lowerBound }
        }
        func take(_ candidate: Candidate, x: CGFloat, width w: CGFloat, text: String) {
            taken.append(x ... x + w)
            placed.append(TimelineRowLabel(id: candidate.id, x: x, width: w, text: text, isMark: candidate.isMark))
        }
        let ordered = candidates.filter(\.isRowName) + candidates.filter { !$0.isRowName }.sorted { $0.anchor < $1.anchor }
        for candidate in ordered {
            let start = max(candidate.anchor, leadingInset)
            var done = false
            for option in [candidate.text] + [candidate.short].compactMap(\.self) where !done {
                let w = measure(option)
                if free(start ... start + w) {
                    take(candidate, x: start, width: w, text: option)
                    done = true
                } else if let end = candidate.endAnchor, free((end - w) ... end) {
                    take(candidate, x: end - w, width: w, text: option)
                    done = true
                }
            }
            guard !done, candidate.isRowName else { continue }
            let limit = taken.map(\.lowerBound).filter { $0 > start }.min().map { $0 - gap } ?? width
            let room = min(limit, width) - start
            if room >= minimumCut { take(candidate, x: start, width: room, text: candidate.text) }
        }
        return placed.sorted { $0.x < $1.x }
    }
}
