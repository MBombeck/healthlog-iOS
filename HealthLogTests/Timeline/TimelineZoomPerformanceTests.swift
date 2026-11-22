import Foundation
@testable import HealthLog
import Testing

/// What a pinch costs: every frame of a zoom builds the board's rows for the
/// new window again. Measured on the realistic hermetic record (three years,
/// medications with dose changes, an illness, labs, a symptom) and on a
/// heavy one (eight lines of daily values over three years), one zoom of
/// 120 frames from three years down to a week. The figure is printed for the
/// report. The bounds are ten times a 120 Hz frame on purpose: the gate
/// machine runs under heavy load, and the bound is there to catch a return
/// of the old cost (parsing every date on every frame, 19 ms), not to time
/// a frame.
@Suite("Timeline — cost of a zoom frame", .serialized)
struct TimelineZoomPerformanceTests {
    static let today = TimelineDay.number("2026-11-17") ?? 0

    /// Eight lines with a value on every day for three years, plus the
    /// fixture's lanes.
    static func heavyRead() -> TimelineRead {
        let keys = [
            "WEIGHT",
            "BLOOD_PRESSURE_SYS",
            "BLOOD_PRESSURE_DIA",
            "RESTING_HEART_RATE",
            "SLEEP_DURATION",
            "PULSE",
            "ACTIVITY_STEPS",
            "BODY_FAT"
        ]
        let series = keys.enumerated().map { index, key in
            TimelineValueSeries(key: key, unit: nil, points: (0 ..< 1095).map { offset in
                let day = today - offset
                return TimelineValuePoint(t: TimelineDay.key(day), mean: 70 + Double((day * (index + 3)) % 17), count: 3)
            }.reversed())
        }
        return TimelineRead(
            zoom: .range,
            range: TimelineRange(from: TimelineDay.key(today - 1094), to: TimelineDay.key(today), dataFrom: TimelineDay.key(today - 1094)),
            lanes: fixtureRead().lanes,
            bucket: .day,
            series: series
        )
    }

    static func fixtureRead() -> TimelineRead {
        let values = [
            "BLOOD_PRESSURE_SYS",
            "BLOOD_PRESSURE_DIA",
            "WEIGHT",
            "RESTING_HEART_RATE",
            "SLEEP_DURATION",
            "lab:bm_ggt",
            "lab:bm_got",
            "symptom:sd_headache"
        ]
        let object: [String: Any] = ["data": TimelineFixtures.timeline(zoom: "all", from: nil, to: nil, values: values)]
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        struct Envelope: Decodable {
            let data: TimelineRead
        }
        return (try? JSONDecoder.hlDefault.decode(Envelope.self, from: data).data)
            ?? TimelineRead(zoom: .all, range: TimelineRange(from: "", to: "", dataFrom: nil), lanes: [], bucket: .month, series: [])
    }

    /// Mean milliseconds per frame over a zoom of `frames` steps.
    static func millisecondsPerFrame(_ read: TimelineRead, frames: Int = 120) -> Double {
        let wording = TimelineWording(read: read, units: .standard)
        let chosen = read.series.map(\.key) + read.labSeries.map(\.key) + read.symptomSeries.map(\.key)
        var window = TimelineWindow(from: today - 1094, to: today + 30)
        let step = pow(7.0 / 1125.0, 1.0 / Double(frames))
        let clock = ContinuousClock()
        var rows = 0
        let elapsed = clock.measure {
            for _ in 0 ..< frames {
                window = window.zoomed(by: 1 / step, anchor: 0.9, maximumDays: 1200, latestEnd: today + 30)
                let content = TimelineBoardContent.make(
                    read: read, window: window, today: today, chosenValues: chosen, hiddenLanes: [], wording: wording
                )
                rows += content.values.count + content.lanes.count
            }
        }
        #expect(rows > 0)
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        return seconds * 1000 / Double(frames)
    }

    @Test("the realistic record: a zoom frame builds its rows without parsing dates again")
    func realistic() {
        let read = Self.fixtureRead()
        #expect(!read.lanes.isEmpty && !read.series.isEmpty)
        let perFrame = Self.millisecondsPerFrame(read)
        print("timeline-zoom-frame realistic: \(String(format: "%.3f", perFrame)) ms")
        #expect(perFrame < 40)
    }

    @Test("eight daily lines over three years: a zoom frame skips to the window")
    func heavy() {
        let perFrame = Self.millisecondsPerFrame(Self.heavyRead())
        print("timeline-zoom-frame heavy: \(String(format: "%.3f", perFrame)) ms")
        #expect(perFrame < 80)
    }
}
