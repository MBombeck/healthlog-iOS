// Diese Suite testet App-Target-Symbole, die in der SPM-Library nicht enthalten
// sind. SPM-Test-Build überspringt die Datei.
#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing

    /// **Regression: the sleep night header and its summary card must name the
    /// SAME day (parity Build 4 · 4.7, audit `09-…md:142`).**
    ///
    /// ## The bug
    ///
    /// `SleepHypnogramScreen` derived the night's date twice. The navigation
    /// header formatted the wake-day anchor with a UTC-pinned
    /// `Date.FormatStyle`; the summary card directly beneath it rendered
    /// `session.start` — the BEDTIME instant — in the device's local zone. For
    /// a night that starts before local midnight those are different calendar
    /// days, so one screen showed one night under two dates.
    ///
    /// ## Why a fixed instant in a non-UTC zone
    ///
    /// The defect is invisible in UTC and invisible mid-afternoon; it needs a
    /// night whose bedtime instant and wake day straddle a day boundary, read
    /// from a zone offset far enough from UTC to expose it. Everything below is
    /// pinned: literal instants, an explicit `TimeZone`, and a fixed `Locale`,
    /// so the suite cannot pass or fail on the machine's settings.
    @Suite("Sleep night boundary — header and summary agree")
    struct SleepNightBoundaryTests {
        /// UTC-8 in January (no DST), a zone far enough west that a UTC-anchored
        /// wake day and a locally-rendered bedtime instant fall on different
        /// dates for an ordinary night.
        private let losAngeles = TimeZone(identifier: "America/Los_Angeles") ?? .gmt
        /// UTC+13 in January — the eastern mirror. A defect that only shifts one
        /// way would slip past a west-only test.
        private let auckland = TimeZone(identifier: "Pacific/Auckland") ?? .gmt
        private let locale = Locale(identifier: "en_US_POSIX")

        /// The night of Wednesday 2026-01-14 as the server keys it: wake day
        /// `2026-01-14`, decoded to its midnight-UTC anchor.
        ///
        /// Bedtime is 2026-01-14T06:20:00Z — which in Los Angeles is
        /// **2026-01-13 at 22:20**, the previous calendar day. That single
        /// instant is the whole bug: rendered locally it says the 13th, while
        /// the night's wake day is the 14th.
        private func night() -> SleepSession {
            SleepSession(
                night: Date(timeIntervalSince1970: 1_768_348_800), // 2026-01-14T00:00:00Z
                source: "APPLE_HEALTH",
                start: Date(timeIntervalSince1970: 1_768_371_600), // 2026-01-14T06:20:00Z
                end: Date(timeIntervalSince1970: 1_768_400_400), // 2026-01-14T14:20:00Z
                asleepMinutes: 452,
                inBedMinutes: 480,
                awakeMinutes: 28,
                awakenings: 3,
                stages: [.deep: 82, .rem: 104, .core: 266],
                segments: [],
                reconstructed: false
            )
        }

        // MARK: - The fix

        @Test("The summary card names the local WAKE day, not the bedtime day")
        func summaryCardUsesWakeDay() throws {
            let session = night()
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = losAngeles

            let displayed = try #require(SleepNightDay.displayDate(for: session, calendar: calendar))
            let components = calendar.dateComponents([.year, .month, .day], from: displayed)
            #expect(components.year == 2026)
            #expect(components.month == 1)
            // The old code rendered `session.start` locally, which is the 13th.
            #expect(components.day == 14)
        }

        @Test("The bedtime instant really does fall on the previous local day")
        func bedtimeInstantIsThePreviousDay() {
            // Pins the PREMISE of the regression: if this ever stops being true
            // the fixture has drifted and the test above proves nothing.
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = losAngeles
            let session = night()
            let bedtimeDay = calendar.dateComponents([.day], from: session.start).day
            #expect(bedtimeDay == 13)
        }

        @Test("Header and summary card render the identical label", arguments: [
            "America/Los_Angeles", "Pacific/Auckland", "UTC", "Asia/Kolkata"
        ])
        func headerAndSummaryAgree(zoneID: String) throws {
            let zone = try #require(TimeZone(identifier: zoneID))
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            let session = night()

            // What the navigation header paints: the wake-day KEY, re-anchored
            // to local midnight and formatted locally.
            let key = SleepNightDay.dayKey(for: session)
            let headerLabel = try #require(
                SleepNightDay.label(forDayKey: key, timeZone: zone, locale: locale)
            )

            // What the summary card paints, through the same authority.
            let cardDate = try #require(SleepNightDay.displayDate(for: session, calendar: calendar))
            let cardLabel = cardDate.formatted(
                SleepNightDay.labelStyle(timeZone: zone).locale(locale)
            )

            #expect(headerLabel == cardLabel)
            // And both name the wake day itself — not a neighbouring day the
            // timezone maths shifted them onto.
            #expect(headerLabel == "Jan 14, 2026")
        }

        @Test("The wake-day key stays in UTC day-key space")
        func wakeDayKeyIsTimezoneStable() {
            // The key is UTC day-key space by design — the ←/→ navigation does
            // whole-day arithmetic on it, and a device-zone-dependent key would
            // let the arrows skip or repeat a night. Only the DISPLAY is local.
            #expect(SleepNightDay.dayKey(for: night()) == "2026-01-14")
        }

        // MARK: - Key parsing

        @Test("A far-east zone still renders the wake day, not the day before")
        func farEastZoneRendersWakeDay() throws {
            // Auckland is UTC+13 in January: midnight UTC on the 14th is 13:00
            // on the 14th locally, so a UTC-anchored instant happens to survive
            // here — but re-anchoring at local midnight must not push it to the
            // 15th either. This pins the other direction of the off-by-one.
            let label = try #require(
                SleepNightDay.label(forDayKey: "2026-01-14", timeZone: auckland, locale: locale)
            )
            #expect(label == "Jan 14, 2026")
        }

        @Test("A malformed day key yields no date rather than a guess")
        func malformedKeyYieldsNil() {
            #expect(SleepNightDay.localAnchor(forDayKey: "not-a-date") == nil)
            #expect(SleepNightDay.localAnchor(forDayKey: "2026-01") == nil)
            #expect(SleepNightDay.label(forDayKey: "", timeZone: .gmt, locale: locale) == nil)
        }

        // MARK: - Clock-time rendering (chronotype measures)

        @Test("Minutes-of-day render as a wall clock without dragging in a zone")
        func minutesOfDayRenderAsClock() {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = losAngeles
            calendar.locale = locale
            // 255 min = 04:15. The chronotype midpoint is a clock POSITION in
            // the user's own day, so no timezone conversion may be applied.
            let rendered = SleepDurationFormat.clockTime(minutesOfDay: 255, calendar: calendar)
            #expect(rendered.contains("4"))
            #expect(rendered.contains("15"))
        }

        @Test("Minutes-of-day wrap instead of overflowing the clock")
        func minutesOfDayWrap() {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .gmt
            calendar.locale = locale
            // The MSFsc correction can push a midpoint below zero; it must wrap
            // onto the wall clock rather than render a negative hour.
            let wrapped = SleepDurationFormat.clockTime(minutesOfDay: -60, calendar: calendar)
            let equivalent = SleepDurationFormat.clockTime(minutesOfDay: 1380, calendar: calendar)
            #expect(wrapped == equivalent)
        }
    }

#endif
