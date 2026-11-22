import Foundation
@testable import HealthLog
import SwiftUI
import Testing

/// The time axis names its steps without a collision: "Jan. 2024Apr" on
/// "Alle" and "Jan. 2026Feb" on the year view ran together on the iPad. Every
/// quick period at a phone, the Duo outside, an iPad upright and an iPad 13 across, in all
/// three languages, measured with the axis font.
@Suite("Timeline axis labels never collide")
struct TimelineAxisLabelTests {
    static let today = TimelineDay.number(year: 2026, month: 11, day: 19)
    /// Three years of record, like the picture walk's account, from before 2024.
    static let dataFrom = TimelineDay.number(year: 2023, month: 12, day: 4)
    static let locales = ["de_DE", "en_US", "nl_NL"].map(Locale.init(identifier:))

    /// The plot and its leading inset at a window width: edge to edge on the
    /// phone, the board's plot column from 600 pt of content on.
    static func plot(windowWidth: CGFloat) -> (width: CGFloat, inset: CGFloat) {
        let content = windowWidth - 2 * HLLayout.pageMargin
        if TimelineLayoutStyle.style(width: content) == .stacked {
            return (content + 2 * HLLayout.pageMargin, HLLayout.pageMargin)
        }
        return (TimelineBoardView.boardColumns(width: content, density: .regular).plot, 0)
    }

    static func measure(_ text: String) -> CGFloat {
        TimelineAxisLabels.measurer(.caption1, weight: .regular, typeSize: .large)(text)
    }

    static func measureToday(_ text: String) -> CGFloat {
        TimelineAxisLabels.measurer(.caption2, weight: .medium, typeSize: .large)(text)
    }

    @Test("no name touches another, Heute or an edge", arguments: TimelinePeriod.allCases, [CGFloat(390), 466, 744, 1376])
    func noCollision(period: TimelinePeriod, windowWidth: CGFloat) {
        let plot = Self.plot(windowWidth: windowWidth)
        let window = period.window(today: Self.today, dataFrom: Self.dataFrom)
        let todayWidth = Self.measureToday("Vandaag")
        for locale in Self.locales {
            let labels = TimelineAxisLabels.labels(
                window: window, today: Self.today, width: plot.width, leadingInset: plot.inset,
                todayWidth: todayWidth, locale: locale, measure: { Self.measure($0) }
            )
            #expect(labels.count >= (period == .week ? 1 : 2), "\(period) at \(windowWidth) in \(locale.identifier): \(labels.map(\.text))")
            let spans = labels.map { label in
                let left = label.x + TimelineAxisLabels.lineInset
                return left ... left + Self.measure(label.text)
            }
            for span in spans {
                #expect(span.lowerBound >= plot.inset && span.upperBound <= plot.width)
            }
            for (left, right) in zip(spans, spans.dropFirst()) {
                #expect(left.upperBound + TimelineAxisLabels.gap <= right.lowerBound, "\(labels.map(\.text))")
            }
            if let today = TimelineAxisLabels.todaySpan(window: window, today: Self.today, width: plot.width, todayWidth: todayWidth) {
                // "Heute" stands whole inside the plot: never cut to "Heu", never past its edge.
                #expect(today.lowerBound >= 0 && today.upperBound <= plot.width)
                #expect(spans
                    .allSatisfy {
                        $0.upperBound + TimelineAxisLabels.gap <= today.lowerBound || $0.lowerBound >= today.upperBound + TimelineAxisLabels
                            .gap
                    })
            }
        }
    }

    @Test("on long windows January is named by its year and every year shows", arguments: [TimelinePeriod.year, .all], [CGFloat(744), 1376])
    func yearsStand(period: TimelinePeriod, windowWidth: CGFloat) {
        let plot = Self.plot(windowWidth: windowWidth)
        let window = period.window(today: Self.today, dataFrom: Self.dataFrom)
        let labels = TimelineAxisLabels.labels(
            window: window, today: Self.today, width: plot.width, leadingInset: plot.inset,
            todayWidth: Self.measureToday("Heute"), locale: Locale(identifier: "de_DE"), measure: { Self.measure($0) }
        )
        let texts = labels.map(\.text)
        #expect(texts.contains("2026"), "\(texts)")
        #expect(!texts.contains { $0.hasPrefix("Jan") }, "\(texts)")
        if period == .all {
            #expect(texts.contains("2024") && texts.contains("2025"), "\(texts)")
        }
    }

    @Test("the first month carries its year only where it fits")
    func firstMonthYear() {
        let window = TimelineWindow(
            from: TimelineDay.number(year: 2026, month: 3, day: 1),
            to: TimelineDay.number(year: 2026, month: 11, day: 30)
        )
        let wide = TimelineAxisLabels.labels(
            window: window, today: Self.today, width: 900, todayWidth: 30, locale: Locale(identifier: "de_DE"),
            measure: { Self.measure($0) }
        )
        #expect(wide.first?.text.contains("2026") == true, "\(wide.map(\.text))")
        let text = TimelineAxisLabels.text(
            TimelineDay.number(year: 2026, month: 1, day: 1), step: .month, withYear: true, today: Self.today,
            locale: Locale(identifier: "de_DE")
        )
        #expect(text == "2026")
    }
}
