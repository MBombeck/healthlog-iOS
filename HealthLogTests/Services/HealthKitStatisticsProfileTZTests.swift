import Foundation
@testable import HealthLog
import Testing

#if canImport(HealthKit)

    /// **Audit B-7 — daily statistics anchor on the profile zone, not the device.**
    ///
    /// `HealthKitStatisticsService` derived `dayKey` and the `measuredAt`
    /// day-start from a calendar frozen at construction time — in production
    /// `.current`, i.e. the DEVICE zone. The server consolidates the same rows by
    /// the profile zone (`consolidation-tz.ts`), so a device zone that differs
    /// from the profile (travel, a wrong device setting) moved a whole day total
    /// onto the neighbouring day.
    ///
    /// The service now takes the same live profile-zone provider the medication /
    /// dashboard day keys read (`ProfileTimeZoneBox`). These tests pin the
    /// resolution rule with fixed instants across the date line and across a DST
    /// boundary — no process-wide time-zone mutation.
    @Suite("HealthKitStatisticsService — B-7 profile-zone day anchor")
    struct HealthKitStatisticsProfileTZTests {
        private func zone(_ identifier: String) throws -> TimeZone {
            try #require(TimeZone(identifier: identifier))
        }

        private func calendar(_ timeZone: TimeZone) -> Calendar {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = timeZone
            return cal
        }

        // MARK: - the resolver

        @Test("nil provider zone leaves the base calendar untouched")
        func nilZoneKeepsBase() throws {
            let base = try calendar(zone("America/New_York"))
            let resolved = HealthKitStatisticsService.dayAnchorCalendar(base: base, timeZone: nil)
            #expect(resolved.timeZone == base.timeZone)
        }

        @Test("a provider zone overrides the base calendar zone")
        func providerZoneOverrides() throws {
            let base = try calendar(zone("America/New_York"))
            let berlin = try zone("Europe/Berlin")
            let resolved = HealthKitStatisticsService.dayAnchorCalendar(base: base, timeZone: berlin)
            #expect(resolved.timeZone == berlin)
            #expect(resolved.identifier == base.identifier, "only the zone is replaced")
        }

        // MARK: - the instance seam

        @Test("the service anchors on the injected profile zone, not the device calendar")
        func serviceUsesProfileZone() async throws {
            let berlin = try zone("Europe/Berlin")
            let service = try HealthKitStatisticsService(
                calendar: calendar(zone("America/New_York")),
                timeZoneProvider: { berlin }
            )
            let anchor = await service.dayAnchorCalendar
            #expect(anchor.timeZone == berlin)
        }

        @Test("a later profile-zone emission is honoured without rebuilding the service")
        func providerIsReadLive() async throws {
            // Audit B-7 — an isolated suite: `update` now mirrors the identifier
            // into `UserDefaults`, and a test must not write into the process
            // store other cases read.
            let box = try ProfileTimeZoneBox(
                defaults: #require(UserDefaults(suiteName: "b7.live.\(UUID().uuidString)"))
            )
            let service = try HealthKitStatisticsService(
                calendar: calendar(zone("America/New_York")),
                timeZoneProvider: { box.current }
            )
            let berlin = try zone("Europe/Berlin")
            box.update(berlin)
            #expect(await service.dayAnchorCalendar.timeZone == berlin)
            let tokyo = try zone("Asia/Tokyo")
            box.update(tokyo)
            #expect(await service.dayAnchorCalendar.timeZone == tokyo)
        }

        // MARK: - the day keys the server has to agree with

        /// 2023-03-26T00:30:00Z — the morning Berlin switches to CEST (02:00 →
        /// 03:00). Berlin reads 01:30 on Mar 26, New York 20:30 on Mar 25.
        @Test("across a DST boundary the day key follows the profile zone")
        func dstBoundaryDayKey() async throws {
            let instant = Date(timeIntervalSince1970: 1_679_790_600)
            let berlin = try zone("Europe/Berlin")
            let newYork = try zone("America/New_York")
            let service = HealthKitStatisticsService(
                calendar: calendar(newYork),
                timeZoneProvider: { berlin }
            )
            let anchor = await service.dayAnchorCalendar
            #expect(HealthKitStatisticsService.dayKey(for: instant, calendar: anchor) == "2023-03-26")
            #expect(
                HealthKitStatisticsService.dayKey(for: instant, calendar: calendar(newYork)) == "2023-03-25",
                "the device zone would have posted the neighbouring day"
            )
        }

        /// 2023-11-21T11:00:00Z across the date line: Kiritimati (UTC+14) is
        /// already Nov 22, Niue (UTC-11) is still Nov 21.
        @Test("across the date line the day key follows the profile zone")
        func dateLineDayKey() async throws {
            let instant = Date(timeIntervalSince1970: 1_700_564_400)
            let kiritimati = try zone("Pacific/Kiritimati")
            let niue = try zone("Pacific/Niue")
            let service = HealthKitStatisticsService(
                calendar: calendar(niue),
                timeZoneProvider: { kiritimati }
            )
            let anchor = await service.dayAnchorCalendar
            #expect(HealthKitStatisticsService.dayKey(for: instant, calendar: anchor) == "2023-11-22")
            #expect(HealthKitStatisticsService.dayKey(for: instant, calendar: calendar(niue)) == "2023-11-21")
        }
    }

#endif
