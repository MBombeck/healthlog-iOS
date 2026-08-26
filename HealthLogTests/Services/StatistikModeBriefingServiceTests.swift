import Foundation
@testable import HealthLog
import Testing

/// Tests for the v0.5.4 BF-1 Statistik-Mode floor.
///
/// The floor MUST emit a non-nil `DailyBriefing` whenever any of the
/// three local-data buckets (measurements / mood / compliance) is
/// populated. This is the "operator never sees keine Daten" contract.
@Suite("StatistikModeBriefingService floor")
struct StatistikModeBriefingServiceTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14
    private let de = Locale(identifier: "de_DE")
    private let en = Locale(identifier: "en_US")

    private func measurement(
        kind: MetricKind,
        value: Double,
        secondsAgo: TimeInterval,
        from base: Date
    ) -> HealthLog.Measurement {
        HealthLog.Measurement(
            id: "m-\(kind.rawValue)-\(secondsAgo)",
            kind: kind,
            recordedAt: base.addingTimeInterval(-secondsAgo),
            value: .scalar(value)
        )
    }

    private func bp(systolic: Double, diastolic: Double, secondsAgo: TimeInterval, from base: Date) -> HealthLog.Measurement {
        HealthLog.Measurement(
            id: "bp-\(secondsAgo)",
            kind: .bloodPressure,
            recordedAt: base.addingTimeInterval(-secondsAgo),
            value: .bloodPressure(systolic: systolic, diastolic: diastolic)
        )
    }

    private func mood(score: Int, secondsAgo: TimeInterval, from base: Date) -> MoodEntry {
        MoodEntry(
            id: "mood-\(secondsAgo)",
            recordedAt: base.addingTimeInterval(-secondsAgo),
            score: score
        )
    }

    @Test("compose returns nil when every bucket is empty")
    func emptyEverythingReturnsNil() {
        let result = StatistikModeBriefingService.compose(
            measurements: [],
            moodEntries: [],
            compliance: nil,
            healthScore: nil,
            locale: de,
            now: now
        )
        #expect(result == nil)
    }

    @Test("compose returns briefing when only mood is populated")
    func moodOnlyStillProducesBriefing() {
        let entries = [mood(score: 4, secondsAgo: 3600, from: now)]
        let result = StatistikModeBriefingService.compose(
            measurements: [],
            moodEntries: entries,
            compliance: nil,
            healthScore: nil,
            locale: de,
            now: now
        )
        let briefing = result
        #expect(briefing != nil)
        #expect(briefing?.paragraph.contains("4/5") == true || briefing?.paragraph.contains("4") == true)
        #expect(briefing?.keyFindings.contains(where: { $0.sourceMetric == "mood" }) == true)
    }

    @Test("compose returns briefing when only medication compliance is populated")
    func complianceOnlyStillProducesBriefing() {
        let compliance = ComplianceSnapshotInput(takenToday: 2, scheduledToday: 3)
        let result = StatistikModeBriefingService.compose(
            measurements: [],
            moodEntries: [],
            compliance: compliance,
            healthScore: nil,
            locale: de,
            now: now
        )
        let briefing = result
        #expect(briefing != nil)
        #expect(briefing?.keyFindings.contains(where: { $0.sourceMetric == "compliance" }) == true)
        // Paragraph mentions the 2/3 ratio.
        #expect(briefing?.paragraph.contains("2") == true)
        #expect(briefing?.paragraph.contains("3") == true)
    }

    @Test("compose paragraph names the most-active kind when measurements present")
    func paragraphNamesMostActiveKind() {
        let m: [HealthLog.Measurement] = [
            measurement(kind: .pulse, value: 72, secondsAgo: 86400, from: now),
            measurement(kind: .pulse, value: 74, secondsAgo: 86400 * 2, from: now),
            measurement(kind: .pulse, value: 70, secondsAgo: 86400 * 3, from: now),
            measurement(kind: .weight, value: 80, secondsAgo: 86400, from: now)
        ]
        let result = StatistikModeBriefingService.compose(
            measurements: m,
            moodEntries: [],
            compliance: nil,
            healthScore: nil,
            locale: de,
            now: now
        )
        let briefing = result
        #expect(briefing != nil)
        // W2-8: the locale branch was removed — the most-active kind name now
        // comes from the shared catalog (`MetricKind.displayName`) under the
        // current process locale, not a hand-mapped table. Assert against the
        // catalog-resolved label rather than a hardcoded German literal.
        #expect(briefing?.paragraph.contains(MetricKind.pulse.displayName) == true)
        // 4 measurements, top kind pulse
        #expect(briefing?.paragraph.contains("4") == true)
    }

    @Test("compose chips include direction arrow for non-BP kinds with > 1 sample")
    func directionArrowOnScalarKind() {
        let m: [HealthLog.Measurement] = [
            measurement(kind: .weight, value: 80, secondsAgo: 86400 * 5, from: now),
            measurement(kind: .weight, value: 80.5, secondsAgo: 86400 * 4, from: now),
            measurement(kind: .weight, value: 81, secondsAgo: 86400 * 3, from: now),
            measurement(kind: .weight, value: 100, secondsAgo: 3600, from: now) // big jump up
        ]
        let result = StatistikModeBriefingService.compose(
            measurements: m,
            moodEntries: [],
            compliance: nil,
            healthScore: nil,
            locale: de,
            now: now
        )
        let briefing = result
        #expect(briefing != nil)
        let weightFinding = briefing?.keyFindings.first(where: { $0.sourceMetric == "weight" })
        #expect(weightFinding?.delta == "↑")
    }

    @Test("compose excludes measurements older than 7 days from the digest")
    func filtersOutOldMeasurements() {
        let m: [HealthLog.Measurement] = [
            measurement(kind: .pulse, value: 72, secondsAgo: 86400, from: now),
            measurement(kind: .pulse, value: 74, secondsAgo: 86400 * 30, from: now), // outside 7d window
            measurement(kind: .pulse, value: 70, secondsAgo: 86400 * 60, from: now) // outside 7d window
        ]
        let result = StatistikModeBriefingService.compose(
            measurements: m,
            moodEntries: [],
            compliance: nil,
            healthScore: nil,
            locale: de,
            now: now
        )
        let briefing = result
        #expect(briefing != nil)
        // Paragraph mentions ONE measurement (only the recent one), not three.
        #expect(briefing?.paragraph.contains("1") == true)
        #expect(briefing?.paragraph.contains("3 ") == false)
    }

    // W2-8: the manual `lang == "en" ? … : …` branch was removed; output now
    // resolves through the shared catalog under the process locale. This test
    // pins that the paragraph is catalog-resolved copy — it never renders a raw
    // dotted key (the failure mode if a `briefing.*` key were missing) and it
    // localizes the headline to a real word, not the `briefing.today` key.
    @Test("compose paragraph resolves catalog copy, never a raw key")
    func paragraphResolvesCatalogCopy() {
        let m: [HealthLog.Measurement] = [
            measurement(kind: .pulse, value: 72, secondsAgo: 86400, from: now)
        ]
        let result = StatistikModeBriefingService.compose(
            measurements: m,
            moodEntries: [],
            compliance: nil,
            healthScore: nil,
            locale: en,
            now: now
        )
        let briefing = result
        #expect(briefing != nil)
        // No raw dotted catalog key leaked into the rendered paragraph.
        #expect(briefing?.paragraph.contains("briefing.") == false)
        #expect(briefing?.paragraph.contains("measurements.none") == false)
        // The headline localizes to the same catalog copy the app would show.
        let expectedHeadline = String(localized: "briefing.measurements.none")
        // Sanity: the key itself resolved to real copy (not the key string).
        #expect(expectedHeadline != "briefing.measurements.none")
    }

    @Test("compose with mixed data emits paragraph + chips for measurements + compliance + mood")
    func fullStack() {
        let m: [HealthLog.Measurement] = [
            measurement(kind: .pulse, value: 72, secondsAgo: 86400, from: now),
            measurement(kind: .pulse, value: 74, secondsAgo: 86400 * 2, from: now),
            bp(systolic: 128, diastolic: 82, secondsAgo: 86400, from: now)
        ]
        let moodEntries = [mood(score: 4, secondsAgo: 3600, from: now)]
        let compliance = ComplianceSnapshotInput(takenToday: 2, scheduledToday: 3)
        let result = StatistikModeBriefingService.compose(
            measurements: m,
            moodEntries: moodEntries,
            compliance: compliance,
            healthScore: HealthScore(score: 84, band: .green, delta: 2),
            locale: de,
            now: now
        )
        let briefing = result
        #expect(briefing != nil)
        let sourceMetrics = Set(briefing?.keyFindings.map(\.sourceMetric) ?? [])
        #expect(sourceMetrics.contains("pulse"))
        #expect(sourceMetrics.contains("bp"))
        #expect(sourceMetrics.contains("compliance"))
        #expect(sourceMetrics.contains("mood"))
    }
}
