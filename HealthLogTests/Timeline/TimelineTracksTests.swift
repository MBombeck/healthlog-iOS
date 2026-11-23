import Foundation
@testable import HealthLog
import Testing

/// The timeline's rows as pure functions: days and buckets, value lines with
/// their gaps, lab and symptom lines, medications cut at dose changes with
/// pauses as gaps, packed lanes, the summary of a chosen week, the window of
/// each period and the layout at every width the app runs at.
@Suite("Timeline — tracks, lanes and summary")
struct TimelineTracksTests {
    static func day(_ key: String) -> Int {
        TimelineDay.number(key) ?? -1
    }

    // MARK: - Days and buckets

    @Test("day keys round-trip, leap days included; invalid keys are nil")
    func dayNumbers() {
        #expect(TimelineDay.number("1970-01-01") == 0)
        #expect(TimelineDay.key(TimelineDay.number("2024-02-29") ?? 0) == "2024-02-29")
        #expect(TimelineDay.number("2025-02-29") == nil)
        #expect(TimelineDay.number("2026-13-01") == nil)
        #expect(TimelineDay.number("26-1-1") == nil)
        for key in ["1999-12-31", "2000-03-01", "2026-11-17", "2100-02-28"] {
            #expect(TimelineDay.key(TimelineDay.number(key) ?? 0) == key)
        }
        // 2026-11-16 is a Monday.
        #expect(TimelineDay.weekday(Self.day("2026-11-16")) == 0)
        #expect(TimelineDay.weekday(Self.day("2026-11-22")) == 6)
    }

    @Test("buckets start like the server's: Monday, the 1st, the quarter's first month")
    func buckets() {
        let day = Self.day("2026-11-19")
        #expect(TimelineDay.key(TimelineDay.bucketStart(day, .week)) == "2026-11-16")
        #expect(TimelineDay.key(TimelineDay.bucketStart(day, .month)) == "2026-11-01")
        #expect(TimelineDay.key(TimelineDay.bucketStart(day, .quarter)) == "2026-10-01")
        #expect(TimelineDay.key(TimelineDay.bucketAfter(Self.day("2026-11-01"), .month)) == "2026-12-01")
        #expect(TimelineDay.key(TimelineDay.bucketAfter(Self.day("2026-10-01"), .quarter)) == "2027-01-01")
        #expect(TimelineDay.bucketIndex(Self.day("2026-11-23"), .week) - TimelineDay.bucketIndex(day, .week) == 1)
        #expect(TimelineDay.bucketIndex(Self.day("2027-01-05"), .month) - TimelineDay.bucketIndex(day, .month) == 2)
        #expect(TimelineDay.bucketIndex(Self.day("2027-01-05"), .quarter) - TimelineDay.bucketIndex(day, .quarter) == 1)
    }

    // MARK: - Value lines

    static let quarter = TimelineWindow(from: day("2026-09-01"), to: day("2026-11-30"))

    static func weekly(_ starts: [String], counts: [Int]? = nil) -> [TimelineValuePoint] {
        starts.enumerated().map { index, start in
            TimelineValuePoint(t: start, mean: 80 + Double(index), count: counts?[index] ?? 4)
        }
    }

    @Test("neighbouring weeks are one solid run; two missing weeks a dashed bridge; five missing a break")
    func gaps() {
        // Mondays: 7, 14 | gap of two weeks (21, 28 missing) | Oct 5, 12 | five missing | Nov 23.
        let points = Self.weekly(["2026-09-07", "2026-09-14", "2026-10-05", "2026-10-12", "2026-11-23"])
        let track = TimelineValueTrack.meanTrack(
            key: "WEIGHT", source: .measurement, unit: "kg", points: points, bucket: .week, window: Self.quarter
        )
        #expect(track.points.count == 5)
        #expect(track.runs.map { $0.map(\.id) } == [["2026-09-07", "2026-09-14"], ["2026-10-05", "2026-10-12"]])
        #expect(track.bridges.map { $0.map(\.id) } == [["2026-09-14", "2026-10-05"]])
        #expect(track.latest?.id == "2026-11-23")
        // A point stands in the middle of its week.
        #expect(track.points[0].day == Double(Self.day("2026-09-07")) + 3.5)
    }

    @Test("a mean from fewer than three readings is thin; the last step gives the trend")
    func thinAndTrend() {
        let points = [
            TimelineValuePoint(t: "2026-11-02", mean: 90, count: 2),
            TimelineValuePoint(t: "2026-11-09", mean: 88, count: 5)
        ]
        let track = TimelineValueTrack.meanTrack(
            key: "WEIGHT", source: .measurement, unit: "kg", points: points, bucket: .week, window: Self.quarter
        )
        #expect(track.points.map(\.isThin) == [true, false])
        #expect(track.trend == .falling)
        #expect(track.domain.contains(88) && track.domain.contains(90))
        let single = TimelineValueTrack.meanTrack(
            key: "WEIGHT", source: .measurement, unit: "kg", points: [points[1]], bucket: .week, window: Self.quarter
        )
        #expect(single.trend == .unknown && single.runs.isEmpty)
    }

    @Test("buckets outside the window are left out; an empty line is empty")
    func outsideWindow() {
        let track = TimelineValueTrack.meanTrack(
            key: "WEIGHT", source: .measurement, unit: "kg",
            points: Self.weekly(["2026-05-04", "2027-01-04"]), bucket: .week, window: Self.quarter
        )
        #expect(track.isEmpty)
        #expect(track.trend == .unknown)
    }

    @Test("a symptom sits on the fixed scale 0 to 10, a lab line holds its band and marks readings outside it")
    func symptomAndLab() {
        let symptom = TimelineValueTrack.meanTrack(
            key: "symptom:x", source: .symptom, unit: nil,
            points: [TimelineValuePoint(t: "2026-10-05", mean: 3, count: 1)], bucket: .week, window: Self.quarter
        )
        #expect(symptom.domain == 0 ... 10)
        let lab = TimelineLabSeries(
            key: "lab:ggt", biomarkerId: "ggt", name: "GGT", panel: nil, unit: "U/L",
            band: TimelineLabBand(low: nil, high: 60),
            points: [
                TimelineLabPoint(id: "a", date: "2026-09-10", value: 41, rangeStatus: .inRange),
                TimelineLabPoint(id: "b", date: "2026-11-05", value: 72, rangeStatus: .above),
                TimelineLabPoint(id: "c", date: "2025-01-01", value: 90, rangeStatus: .above)
            ],
            excluded: 0
        )
        let track = TimelineValueTrack.labTrack(lab, window: Self.quarter)
        #expect(track.points.map(\.id) == ["a", "b"])
        #expect(track.points.map(\.isOutOfRange) == [false, true])
        #expect(track.domain.contains(60) && track.domain.contains(72) && track.domain.contains(41))
        #expect(track.band == TimelineLabBand(low: nil, high: 60))
        #expect(track.runs.count == 1)
        #expect(track.trend == .rising)
    }

    // MARK: - Medications

    static func item(
        _ id: String, _ kind: TimelineItemKind, _ start: String, end: String? = nil, open: Bool = false,
        label: String = "Trulicity", sub: String? = nil, group: String? = "m1"
    ) -> TimelineItem {
        TimelineItem(id: id, kind: kind, start: start, end: end, open: open, label: label, sub: sub, group: group)
    }

    static let trulicity: [TimelineItem] = [
        item("m1", .medication, "2026-02-20", open: true, sub: "2,5 mg"),
        item("d1", .doseChange, "2026-02-20", sub: "2,5 mg"),
        item("d2", .doseChange, "2026-03-24", sub: "5 mg"),
        item("d3", .doseChange, "2026-10-01", sub: "7,5 mg"),
        item("p1", .pause, "2026-10-10", end: "2026-10-16")
    ]

    @Test("one medication, one row: its stretch cut at every dose change, the dose on each piece, a pause as a gap")
    func medicationRow() throws {
        let today = Self.day("2026-11-17")
        let rows = TimelineLaneTrack.medicationRows(Self.trulicity, window: Self.quarter, today: today)
        let row = try #require(rows.first)
        #expect(rows.count == 1)
        #expect(row.title == "Trulicity")
        let bars = row.bars.filter { !$0.isPause }
        // The 2,5 mg piece ends before the window and is left out.
        // The first piece on screen carries the name, the next only its dose.
        #expect(bars.map(\.label) == ["Trulicity 5 mg", "7,5 mg"])
        #expect(bars.map(\.start) == [Self.day("2026-03-24"), Self.day("2026-10-01")])
        #expect(bars[0].endExclusive == Self.day("2026-10-01"))
        #expect(bars[1].open && bars[1].endExclusive == today + 1)
        #expect(bars[1].beginsWithChange)
        let pause = try #require(row.bars.first { $0.isPause })
        #expect(pause.start == Self.day("2026-10-10") && pause.endExclusive == Self.day("2026-10-17"))
    }

    @Test("the first piece carries the name with its dose; a dose before every change is unknown")
    func doseAt() throws {
        let group = try #require(TimelineMedicationGroup.groups(Self.trulicity).first)
        #expect(group.dose(on: "2026-01-01") == nil)
        #expect(group.dose(on: "2026-03-24") == "5 mg")
        #expect(group.dose(on: "2026-11-17") == "7,5 mg")
        let segments = group.segments(of: group.periods[0])
        #expect(segments.map(\.dose) == ["2,5 mg", "5 mg", "7,5 mg"])
        let wide = TimelineWindow(from: Self.day("2026-01-01"), to: Self.day("2026-11-30"))
        let row = try #require(TimelineLaneTrack.medicationRows(Self.trulicity, window: wide, today: Self.day("2026-11-17")).first)
        #expect(row.bars.first?.label == "Trulicity 2,5 mg")
    }

    @Test("courses are the stretches, the own span after the last course too; a one-time intake is a mark")
    func coursesAndMarks() {
        let items = [
            Self.item("o1", .medication, "2026-06-01", open: true, label: "Omega 3", sub: "2 Kapseln", group: "o1"),
            Self.item("c1", .course, "2026-06-01", end: "2026-09-20", label: "Omega 3", group: "o1"),
            Self.item("i1", .medication, "2026-10-03", end: "2026-10-03", label: "Naproxen", sub: "400 mg", group: "i1")
        ]
        let rows = TimelineLaneTrack.medicationRows(items, window: Self.quarter, today: Self.day("2026-11-17"))
        #expect(rows.map(\.title) == ["Omega 3", "Naproxen"])
        // Taken again since the course ended: the medication's own span from the next day.
        let omega = rows[0]
        #expect(omega.bars.map(\.start) == [Self.day("2026-06-01"), Self.day("2026-09-21")])
        #expect(omega.marks.map(\.label) == [])
        #expect(rows[1].marks.map(\.label) == ["Naproxen 400 mg"])
        #expect(rows[1].bars.isEmpty)
    }

    @Test("overlapping spans stack on rows; points stand on a row of their own above them")
    func packedLanes() {
        let items = [
            Self.item("e1", .episode, "2026-09-05", end: "2026-09-20", label: "Erkältung", group: nil),
            Self.item("e2", .episode, "2026-09-15", end: "2026-09-25", label: "Bronchitis", group: nil),
            Self.item("e3", .episode, "2026-10-01", end: "2026-10-08", label: "Infekt", group: nil),
            Self.item("v1", .visit, "2026-09-16", label: "Hausarzt", group: nil),
            Self.item("old", .episode, "2025-01-01", end: "2025-01-05", label: "Alt", group: nil)
        ]
        let rows = TimelineLaneTrack.packedRows(
            items, key: .illness, window: Self.quarter, today: Self.day("2026-11-17"), words: \.label
        )
        #expect(rows.count == 3)
        #expect(rows[0].marks.map(\.label) == ["Hausarzt"])
        #expect(rows[1].bars.map(\.label) == ["Erkältung", "Infekt"])
        #expect(rows[2].bars.map(\.label) == ["Bronchitis"])
    }

    @Test("lanes follow the server's order; a hidden or empty lane has no track")
    func laneOrderAndHiding() {
        let read = TimelineRead(
            zoom: .quarter,
            range: TimelineRange(from: "2026-08-19", to: "2026-11-17", dataFrom: "2023-01-01"),
            lanes: [
                TimelineLane(key: .medications, items: Self.trulicity),
                TimelineLane(
                    key: .illness,
                    items: [Self.item("e1", .episode, "2026-10-01", end: "2026-10-08", label: "Infekt", group: nil)]
                ),
                TimelineLane(key: .visits, items: [Self.item("v", .visit, "2025-01-01", label: "Alt", group: nil)])
            ],
            bucket: .week,
            series: []
        )
        let today = Self.day("2026-11-17")
        let all = TimelineLaneTrack.tracks(read: read, window: Self.quarter, today: today, hidden: [], words: \.label)
        #expect(all.map(\.key) == [.illness, .medications])
        let hidden = TimelineLaneTrack.tracks(read: read, window: Self.quarter, today: today, hidden: [.illness], words: \.label)
        #expect(hidden.map(\.key) == [.medications])
    }

    // MARK: - Summary

    @Test("the summary of a week: entries touching it, a medication once with its new dose, means and lab readings")
    func summary() {
        let read = TimelineRead(
            zoom: .quarter,
            range: TimelineRange(from: "2026-08-19", to: "2026-11-17", dataFrom: "2023-01-01"),
            lanes: [
                TimelineLane(key: .medications, items: Self.trulicity),
                TimelineLane(key: .illness, items: [
                    Self.item("e1", .episode, "2026-09-30", end: "2026-10-03", label: "Infekt", group: nil),
                    Self.item("c1", .chronic, "2023-01-01", open: true, label: "Bluthochdruck", group: nil)
                ])
            ],
            bucket: .week,
            series: [TimelineValueSeries(key: "WEIGHT", unit: "kg", points: [TimelineValuePoint(t: "2026-09-28", mean: 89.2, count: 3)])],
            labSeries: [TimelineLabSeries(
                key: "lab:ggt", biomarkerId: "ggt", name: "GGT", panel: nil, unit: "U/L", band: nil,
                points: [TimelineLabPoint(id: "r", date: "2026-10-02", value: 72, rangeStatus: .above)], excluded: 0
            )]
        )
        let summary = TimelineSummary.make(read: read, day: Self.day("2026-10-01"), today: Self.day("2026-11-17"), hidden: [])
        #expect(TimelineDay.key(summary.from) == "2026-09-28" && TimelineDay.key(summary.to) == "2026-10-04")
        // The open chronic condition is the backdrop and left out.
        #expect(summary.entries.map(\.item.label) == ["Infekt", "Trulicity"])
        #expect(summary.entries.last?.item.sub == "7,5 mg")
        #expect(summary.values == [TimelineSummary.Value(key: "WEIGHT", mean: 89.2, count: 3)])
        #expect(summary.readings.map(\.point.id) == ["r"])
        #expect(!summary.isEmpty)

        let paused = TimelineSummary.make(read: read, day: Self.day("2026-10-12"), today: Self.day("2026-11-17"), hidden: [])
        #expect(paused.entries.map(\.item.kind) == [.pause])
        let hidden = TimelineSummary.make(read: read, day: Self.day("2026-10-01"), today: Self.day("2026-11-17"), hidden: [.medications])
        #expect(hidden.entries.map(\.item.label) == ["Infekt"])
        // The newest day anything ends on: the pause's last day.
        #expect(TimelineSummary.latestDataDay(read: read, window: Self.quarter, today: Self.day("2026-11-17")) == Self.day("2026-10-16"))
    }

    // MARK: - Windows and layout

    @Test("a quick choice spans its days up to today with a twelfth of room after it; everything starts at the record")
    func periodWindows() {
        let today = Self.day("2026-11-17")
        let quarter = TimelinePeriod.quarter.window(today: today, dataFrom: nil)
        #expect(quarter.span == 91 && quarter.to == today + 7)
        let week = TimelinePeriod.week.window(today: today, dataFrom: nil)
        #expect(week.span == 7 && week.to == today + 1)
        let all = TimelinePeriod.all.window(today: today, dataFrom: Self.day("2023-11-18"))
        #expect(all.from == Self.day("2023-11-18") && all.to > today)
        #expect(TimelinePeriod.allCases == [.week, .month, .quarter, .halfYear, .year, .all])
        #expect(!TimelinePeriod.allCases.contains(.custom))
    }

    @Test("a window asks for a range up to today, its length picks the server's bucket; everything asks for all")
    func requests() {
        let today = Self.day("2026-11-17")
        let half = TimelinePeriod.request(for: TimelinePeriod.halfYear.window(today: today, dataFrom: nil), period: .halfYear, today: today)
        #expect(half == TimelinePeriod.Request(zoom: .range, from: "2026-06-04", to: "2026-11-17"))
        #expect(TimelinePeriod.request(for: Self.quarter, period: .all, today: today) == TimelinePeriod.Request(zoom: .all))
        let future = TimelineWindow(from: today + 3, to: today + 9)
        let request = TimelinePeriod.request(for: future, period: .custom, today: today)
        #expect(request.from == request.to && request.to == "2026-11-17")
    }

    @Test("zooming holds the day under the fingers, stops at a week and at the longest window, never runs far past today")
    func zoom() {
        let today = Self.day("2026-11-17")
        let quarter = TimelinePeriod.quarter.window(today: today, dataFrom: nil)
        let closer = quarter.zoomed(by: 2, anchor: 0.5, maximumDays: 1000, latestEnd: today + 7)
        #expect(abs(closer.span - 46) <= 1)
        let middle = Double(quarter.from) + Double(quarter.span) / 2
        let newMiddle = Double(closer.from) + Double(closer.span) / 2
        #expect(abs(middle - newMiddle) <= 1)
        let tight = quarter.zoomed(by: 100, anchor: 1, maximumDays: 1000, latestEnd: today + 7)
        #expect(tight.span == TimelineWindow.minimumSpan && tight.to <= today + 7)
        let wide = quarter.zoomed(by: 0.01, anchor: 0.5, maximumDays: 400, latestEnd: today + 7)
        #expect(wide.span == 400 && wide.to <= today + 7)
        let moved = quarter.panned(by: -30, latestEnd: today + 7)
        #expect(moved.from == quarter.from - 30 && moved.span == quarter.span)
        #expect(quarter.panned(by: 30, latestEnd: today + 7).to == today + 7)
        #expect(TimelineSelectionLayer.days(forSwipe: 100, width: 400, span: 92) == -23)
    }

    @Test("on a 420 pt plot the axis steps from days to years as the window grows; marks start on their step", arguments: [
        (7, TimelineAxisStep.day), (30, .week), (91, .month), (182, .month), (365, .quarter), (1100, .year), (3650, .year)
    ])
    func axisSteps(span: Int, expected: TimelineAxisStep) {
        let window = TimelineWindow(from: Self.day("2026-11-24") - span + 1, to: Self.day("2026-11-24"))
        let step = TimelineAxisStep.step(window: window, width: 420)
        #expect(step == expected)
        let starts = step.starts(in: window)
        #expect(starts.allSatisfy { window.contains($0) })
        switch step {
        case .week: #expect(starts.allSatisfy { TimelineDay.weekday($0) == 0 })
        case .month, .quarter: #expect(starts.allSatisfy { TimelineDay.components($0).day == 1 })
        case .year: #expect(starts.allSatisfy { TimelineDay.components($0).month == 1 && TimelineDay.components($0).day == 1 })
        case .day: #expect(starts.count == 7)
        }
    }

    @Test("a young record's three months start at its first entry, at least four weeks back")
    func youngRecord() {
        let today = Self.day("2026-11-17")
        let quarter = TimelineWindow(from: Self.day("2026-09-01"), to: Self.day("2026-11-30"))
        #expect(TimelinePeriod.youngRecordWindow(quarter, dataFrom: Self.day("2026-10-10"), today: today).from == Self.day("2026-10-10"))
        #expect(TimelinePeriod.youngRecordWindow(quarter, dataFrom: Self.day("2026-11-12"), today: today).from == today - 27)
        #expect(TimelinePeriod.youngRecordWindow(quarter, dataFrom: Self.day("2024-01-01"), today: today) == quarter)
    }

    static let widths: [CGFloat] = [320, 440, 466, 540, 669, 744, 834, 1032, 1133, 1376]

    @Test("upright phones and narrow windows stack the names above the tracks; from 600 pt the full board", arguments: widths)
    func layoutStyle(width: CGFloat) {
        let style = TimelineLayoutStyle.style(width: width)
        #expect(style == (width >= 600 ? .board : .stacked))
        if style == .board {
            let column = TimelineLayoutStyle.labelColumnWidth(width: width)
            #expect(column >= 180 && column <= 240)
            #expect(width - column >= 380)
        }
    }

    @Test("the chosen period's value of a line: the bucket's mean, or a lab marker's last reading in it")
    func valueInBucket() {
        let points = Self.weekly(["2026-10-05", "2026-10-12"])
        let track = TimelineValueTrack.meanTrack(
            key: "WEIGHT", source: .measurement, unit: "kg", points: points, bucket: .week, window: Self.quarter
        )
        #expect(TimelineValueLabel.value(of: track, inBucketOf: Self.day("2026-10-14"), bucket: .week) == 81)
        #expect(TimelineValueLabel.value(of: track, inBucketOf: Self.day("2026-10-20"), bucket: .week) == nil)
    }

    @Test("VoiceOver names a lab line's reference range in words, a line without one stays silent about it")
    func spokenRange() {
        #expect(TimelineAccessibility
            .range(TimelineLabBand(low: nil, high: 60)) ==
            String(localized: "timeline.labs.rangeUpTo \(HLNumberFormat.decimal(60, maximumFractionDigits: 2))"))
        #expect(TimelineAccessibility.range(TimelineLabBand(low: 4, high: 5.6)) != nil)
        #expect(TimelineAccessibility.range(nil) == nil)
    }

    @Test("a swipe moves the axis only when it runs sideways")
    func sideways() {
        #expect(TimelineSidewaysPan.isSideways(CGPoint(x: 300, y: 40)))
        #expect(!TimelineSidewaysPan.isSideways(CGPoint(x: 120, y: 200)))
        #expect(!TimelineSidewaysPan.isSideways(CGPoint(x: 0, y: 0)))
    }

    @Test("only a compact phone opens the timeline across; the iPad and the open Duo keep their page")
    func opensAcross() {
        #expect(OrientationPolicy.opensAcross(isPad: false, isCompactWidth: true))
        #expect(!OrientationPolicy.opensAcross(isPad: false, isCompactWidth: false))
        #expect(!OrientationPolicy.opensAcross(isPad: true, isCompactWidth: true))
    }

    @Test("a fraction of the axis maps back to its day, clamped into the window")
    func windowMapping() {
        let window = Self.quarter
        #expect(window.day(atFraction: 0) == window.from)
        #expect(window.day(atFraction: 1) == window.to)
        #expect(window.day(atFraction: -2) == window.from)
        #expect(window.fraction(Double(window.from)) == 0)
        let band = TimelineSelectionLayer.bandRange(day: Self.day("2026-11-18"), bucket: .week, window: window, width: 910)
        #expect(band.width == 70 && band.minX == CGFloat(window.fraction(Double(Self.day("2026-11-16")))) * 910)
    }
}
