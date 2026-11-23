import CoreGraphics
import Foundation
@testable import HealthLog
import Testing

/// The Insights strip keeps every pill inside the screen: at the largest text
/// sizes a long metric name shrinks into the strip instead of growing the
/// capsule past both edges.
@Suite("Insights strip: a pill title never outgrows the strip")
struct N2InsightsStripPillTests {
    @Test("the cap is the strip less its margins and the capsule's padding")
    func capLeavesMarginsAndPadding() throws {
        let cap = try #require(InsightsMetricTabStrip.pillTitleMaxWidth(stripWidth: 402))
        #expect(cap == 402 - 2 * HLSpace.lg - 2 * HLSpace.md)
    }

    @Test("a category pill leaves room for its chevron")
    func categoryLeavesChevronRoom() throws {
        let plain = try #require(InsightsMetricTabStrip.pillTitleMaxWidth(stripWidth: 402))
        let category = try #require(InsightsMetricTabStrip.pillTitleMaxWidth(stripWidth: 402, trailing: HLSpace.xl))
        #expect(category == plain - HLSpace.xl)
    }

    @Test("an unmeasured strip does not cap the title")
    func unmeasuredStripLeavesTitleAlone() {
        #expect(InsightsMetricTabStrip.pillTitleMaxWidth(stripWidth: 0) == nil)
    }

    @Test("a title narrower than the cap keeps its width, a wider one gets the cap")
    func cappedWidth() {
        #expect(InsightsCappedWidthLayout.width(natural: 120, cap: 300) == 120)
        #expect(InsightsCappedWidthLayout.width(natural: 420, cap: 300) == 300)
        #expect(InsightsCappedWidthLayout.width(natural: 420, cap: nil) == 420)
    }

    @Test("titles shrink further only at the accessibility sizes")
    func shrinkOnlyAtAccessibilitySizes() {
        #expect(InsightsMetricTabStrip.pillTitleScale(isAccessibilitySize: false) == 0.8)
        #expect(InsightsMetricTabStrip.pillTitleScale(isAccessibilitySize: true) == 0.5)
    }
}

/// Times of day on the Insights pages follow the 12- or 24-hour choice.
@Suite("Insights times: the hour windows follow the clock setting")
struct N2InsightsClockTests {
    private static let morning = BloodPressureTimeOfDay.PartSummary(
        part: .morning,
        startHour: 4,
        endHour: 12,
        readingCount: 6,
        systolic: 130,
        diastolic: 84,
        pulseReadingCount: 6,
        pulse: 70
    )

    @Test("the 24-hour clock reads 04:00 to 11:59")
    func twentyFourHour() {
        let text = BloodPressureTimeOfDaySection.hours(Self.morning, locale: Locale(identifier: "de_DE"))
        #expect(text.contains("04:00"))
        #expect(text.contains("11:59"))
    }

    @Test("the 12-hour clock reads 4:00 AM to 11:59 AM")
    func twelveHour() {
        let text = BloodPressureTimeOfDaySection.hours(Self.morning, locale: Locale(identifier: "en_US"))
        #expect(text.contains("4:00"))
        #expect(text.contains("11:59"))
        #expect(text.contains("AM"))
        #expect(!text.contains("04:00"))
    }
}

/// Dates on the chart pages go through the shared helpers.
@Suite("Insights dates: chart lines name the year only when it is not this one")
struct N2InsightsChartDateTests {
    @Test("a day of this year has no year, a day of an earlier year has it")
    func coachLineYear() throws {
        let calendar = Calendar(identifier: .gregorian)
        let year = calendar.component(.year, from: Date())
        let thisYear = try #require(ChartCoachReadLine.dayText("\(year)-03-04", calendar: calendar))
        let earlier = try #require(ChartCoachReadLine.dayText("\(year - 2)-03-04", calendar: calendar))
        #expect(!thisYear.contains(String(year)))
        #expect(earlier.contains(String(year - 2)))
    }

    @Test("the lab overlay names the full date")
    func labOverlayDate() {
        #expect(ChartLabOverlay.dayText("2024-10-02").contains("2024"))
    }

    @Test("the spoken point carries the time in the chosen clock")
    func announcementCarriesTime() {
        let at = Date(timeIntervalSince1970: 1_700_000_000)
        let point = SeriesPoint(id: "p", at: at, value: 72.4, secondary: nil)
        let announcement = ChartsAccessibility.selectedPointAnnouncement(point: point, kind: .weight)
        #expect(announcement.contains(HLTimeFormat.time(at)))
        #expect(announcement.contains(HLDateFormat.weekdayDayMonth(at)))
    }
}
