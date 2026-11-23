import Foundation
@testable import HealthLog
import Testing

/// Labs, documents, diary and sharing in the one form of the reference pages:
/// short values on the right, counters that count what they say, a span that
/// never runs past today, a preview only where there is something to show.
@MainActor
@Suite("E2 package D: labs, documents, diary, sharing")
struct E2DPagesTests {
    // MARK: - Questionnaire counter

    @Test("The counter runs over the scored questions; the optional follow-up has no number")
    func phq9Counter() throws {
        let first = try #require(MentalWellbeingForm.progress(step: 0, scoredCount: 9))
        #expect(first.current == 1)
        #expect(first.total == 9)
        let last = try #require(MentalWellbeingForm.progress(step: 8, scoredCount: 9))
        #expect(last.current == 9)
        #expect(MentalWellbeingForm.progress(step: 9, scoredCount: 9) == nil)
    }

    // MARK: - Illness episode

    private func deviation(_ sd: Double, _ direction: IllnessDeviationDirection) -> IllnessVitalDeviation {
        IllnessVitalDeviation(
            type: "RESTING_HEART_RATE", day: "2026-09-30", value: 68, baselineCenter: 58,
            deviationSd: sd, direction: direction, adverse: true
        )
    }

    @Test("A deviation reads as a short signed figure, never as a sentence")
    func deviationValue() {
        #expect(IllnessCorrelationSection
            .deviationValue(deviation(2.2, .above)) == "+\(HLValueFormat.number(2.2, fractionDigits: 0 ... 1))")
        #expect(IllnessCorrelationSection.deviationValue(deviation(-1.5, .below)).hasPrefix("−"))
        #expect(!IllnessCorrelationSection.deviationValue(deviation(1, .unknown)).contains(" "))
    }

    @Test("A return shows the day on the right and the gap in the detail line")
    func returnRow() {
        let back = IllnessVitalReturn(type: "RESTING_HEART_RATE", returnedDay: "2026-10-10", gapDays: 3)
        #expect(IllnessCorrelationSection.returnDay(back) == IllnessDateFormat.mediumDate("2026-10-10"))
        #expect(IllnessCorrelationSection.returnDetail(back).contains("3"))
        let open = IllnessVitalReturn(type: "RESTING_HEART_RATE", returnedDay: nil, gapDays: nil)
        #expect(IllnessCorrelationSection.returnDay(open) == nil)
        #expect(IllnessCorrelationSection.returnDetail(open) == String(localized: "illness.correlation.returns.notYet"))
    }

    // MARK: - Sharing

    @Test("The period line ends on the last day of the span, never later")
    func sharingPeriodLine() throws {
        let calendar = Calendar.current
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 15, hour: 9)))
        let lookBack = try #require(UnifiedSharingScreen.lookBack(days: 90, now: now, calendar: calendar))
        #expect(lookBack.end == now)
        let line = try #require(UnifiedSharingScreen.periodLine(lookBack))
        #expect(line.contains(HLDateFormat.date(now)))
        #expect(UnifiedSharingScreen.periodLine(nil) == nil)
    }

    // MARK: - Documents

    @Test("Bytes that are no readable PDF get no preview plate")
    func unreadablePDF() {
        #expect(!DocumentPreviewView.isReadablePDF(Data("not a pdf".utf8)))
        #expect(!DocumentPreviewView.isReadablePDF(Data()))
    }

    // MARK: - Mood

    @Test("A mood entry dated after now does not lead the history")
    func futureMoodHidden() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let past = MoodEntry(id: "a", recordedAt: now.addingTimeInterval(-3600), score: 4)
        let future = MoodEntry(id: "b", recordedAt: now.addingTimeInterval(19 * 3600), score: 4)
        #expect(MoodHistoryScreen.visible([past, future], now: now).map(\.id) == ["a"])
    }

    @Test("The calendar ramp keeps even the lowest level visible and rises with the mood")
    func heatmapRamp() {
        let levels = MoodHeatmapPalette.levelOpacities
        #expect(levels.count == 5)
        #expect(levels.first.map { $0 >= 0.5 } == true)
        #expect(zip(levels, levels.dropFirst()).allSatisfy { $0 < $1 })
        #expect(MoodHeatmapPalette.opacity(forBucket: nil) < levels[0])
        #expect(MoodHeatmapPalette.opacity(forBucket: 1) == levels[0])
    }
}
