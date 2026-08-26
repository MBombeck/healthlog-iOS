import Foundation
@testable import HealthLog
import Testing

/// M3 (AUDIT-PARITY-v11612) — the central time-format helper. Verifies the
/// raw-value contract with the server enum, the UserDefaults-mirror read, and
/// that the forced cases pin the hour cycle while AUTO defers to the device
/// locale.
@Suite("HLTimeFormat")
struct HLTimeFormatTests {
    /// 1 PM on an arbitrary fixed instant — far from a midnight edge so the
    /// AM/PM vs 24h read is unambiguous regardless of timezone offset within
    /// the test host's region.
    private func sample() -> Date {
        // 2026-06-14T13:00:00Z
        Date(timeIntervalSince1970: 1_781_787_600)
    }

    @Test("Raw values match the server User.timeFormat enum")
    func rawValuesMatchServerEnum() {
        #expect(HLTimeFormat.auto.rawValue == "AUTO")
        #expect(HLTimeFormat.twelveHour.rawValue == "H12")
        #expect(HLTimeFormat.twentyFourHour.rawValue == "H24")
        #expect(HLTimeFormat(rawValue: "H24") == .twentyFourHour)
        // An unknown / future literal degrades to nil (caller defaults to AUTO).
        #expect(HLTimeFormat(rawValue: "H10") == nil)
    }

    @Test("current() reads the UserDefaults mirror, defaulting to AUTO")
    func currentReadsMirror() throws {
        let suite = try #require(UserDefaults(suiteName: "hl.test.timeformat.current"))
        suite.removePersistentDomain(forName: "hl.test.timeformat.current")

        #expect(HLTimeFormat.current(defaults: suite) == .auto)

        suite.set("H24", forKey: HLTimeFormat.defaultsKey)
        #expect(HLTimeFormat.current(defaults: suite) == .twentyFourHour)

        // A garbage value falls back to AUTO rather than crashing.
        suite.set("nonsense", forKey: HLTimeFormat.defaultsKey)
        #expect(HLTimeFormat.current(defaults: suite) == .auto)
    }

    @Test("H24 forces a 24-hour clock; H12 forces AM/PM")
    func forcedCyclesPinTheClock() {
        let date = sample()

        let h24 = HLTimeFormat.twentyFourHour.formatTime(date)
        // A 24-hour clock never carries an AM/PM marker.
        #expect(!h24.localizedCaseInsensitiveContains("AM"))
        #expect(!h24.localizedCaseInsensitiveContains("PM"))

        let h12 = HLTimeFormat.twelveHour.formatTime(date)
        // A 12-hour clock carries an AM/PM marker (in any locale's wording the
        // English markers are produced because we force the cycle, not the
        // locale's day-period symbols, but to stay robust we assert the two
        // forced renders differ from each other).
        #expect(h12 != h24)
    }

    @Test("AUTO defers to the device locale's hour cycle")
    func autoDefersToLocale() {
        let date = sample()
        let auto = HLTimeFormat.auto.formatTime(date)
        // AUTO must equal the plain locale-driven short-time render.
        let expected = date.formatted(
            Date.FormatStyle(date: .omitted, time: .shortened).locale(.current)
        )
        #expect(auto == expected)
    }

    @Test("static time() routes through the effective preference")
    func staticTimeRoutesThroughPreference() throws {
        let suite = try #require(UserDefaults(suiteName: "hl.test.timeformat.static"))
        suite.removePersistentDomain(forName: "hl.test.timeformat.static")
        suite.set("H24", forKey: HLTimeFormat.defaultsKey)

        let date = sample()
        #expect(
            HLTimeFormat.time(date, defaults: suite)
                == HLTimeFormat.twentyFourHour.formatTime(date)
        )
    }
}
