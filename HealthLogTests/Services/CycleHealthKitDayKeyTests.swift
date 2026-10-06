import Foundation
@testable import HealthLog
import Testing
#if canImport(HealthKit)
    import HealthKit
#endif

// swiftlint:disable force_unwrapping

#if canImport(HealthKit)

    /// **#115 1.5 — a cycle sample's day, and its `cycle-hk:<day>` id.**
    ///
    /// The server keys cycle days in the account zone and upserts HealthKit day
    /// logs on `(userId, source, externalId)`, with one row per `(userId, date)`
    /// behind it (`upsertCycleDayLog`, `src/lib/cycle/day-log-write.ts`, v1.39.0).
    /// The importer used to cut the day with a formatter frozen on the device
    /// zone. These tests pin the new rule and — the update path — that the ids
    /// an existing install already minted come out unchanged, so a re-import
    /// re-posts the same key and cannot add a second row for a day.
    @Suite("Cycle — HealthKit day key in the profile zone (#115 1.5)", .serialized, .mockURLSession)
    struct CycleHealthKitDayKeyTests {
        private func makeImporter(profile: TimeZone) throws -> CycleHealthKitImporter {
            let env = AppEnvironment(
                baseURL: URL(string: "https://test.healthlog.local")!,
                bundleID: "dev.healthlog.app",
                appVersion: "0.14.8",
                buildNumber: "1"
            )
            let api = APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
            let repo = try CycleRepository(api: api, outbox: OutboxQueue(inMemory: true))
            return CycleHealthKitImporter(
                store: HKHealthStore(),
                repo: repo,
                userID: "test-user",
                defaults: UserDefaults(suiteName: "cycle-hk-daykey-tests.\(UUID().uuidString)")!,
                profileTimeZone: { profile }
            )
        }

        private func zone(_ identifier: String) throws -> TimeZone {
            try #require(TimeZone(identifier: identifier))
        }

        /// A whole-day flow sample as the Health app writes it: midnight to the
        /// next midnight of the zone it was logged in.
        private func wholeDayFlow(on day: String, loggedIn zone: TimeZone) throws -> HKCategorySample {
            let start = try #require(ProfileDay.startOfDay(forKey: day, timeZone: zone))
            let end = try #require(ProfileDay.calendar(in: zone).date(byAdding: .day, value: 1, to: start))
            return flow(start: start, end: end)
        }

        private func flow(start: Date, end: Date) -> HKCategorySample {
            let type = HKObjectType.categoryType(
                forIdentifier: HKCategoryTypeIdentifier(rawValue: CycleHealthKitMapping.menstrualFlow)
            )!
            return HKCategorySample(
                type: type,
                value: 3,
                start: start,
                end: end,
                metadata: [HKMetadataKeyMenstrualCycleStart: false]
            )
        }

        /// What the pre-#115 importer minted: the START instant in the zone the
        /// phone was in when the import ran.
        private func legacyKey(start: Date, deviceZone: TimeZone) -> String {
            let f = DateFormatter()
            f.calendar = Calendar(identifier: .gregorian)
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = deviceZone
            f.dateFormat = "yyyy-MM-dd"
            return f.string(from: start)
        }

        @Test("A whole-day sample keeps the day it was logged on, for a profile zone within 12 h of it")
        func wholeDaySampleKeepsItsDay() async throws {
            // Logged at the date line: Kiritimati (UTC+14) and Pago Pago
            // (UTC−11), plus Berlin. The old key read the START instant in the
            // device zone, which names 2026-09-19 for the Kiritimati entry from
            // any zone west of UTC+14 — a day the person never logged. The
            // midpoint rule holds for every profile zone within ±12 h of the
            // zone the sample was logged in (noon stays on the same date); a
            // profile on the far side of the date line is out of its reach.
            let cases = try [
                (zone("Pacific/Kiritimati"), [zone("Asia/Tokyo"), zone("Pacific/Auckland"), zone("Pacific/Kiritimati")]),
                (zone("Pacific/Pago_Pago"), [zone("America/New_York"), zone("America/Los_Angeles"), zone("Pacific/Honolulu")]),
                (zone("Europe/Berlin"), [zone("Europe/Berlin"), zone("America/New_York"), zone("Asia/Tokyo")])
            ]
            for (loggedIn, profiles) in cases {
                for profile in profiles {
                    let importer = try makeImporter(profile: profile)
                    let writes = try await importer.buildWrites(
                        from: [wholeDayFlow(on: "2026-09-20", loggedIn: loggedIn)],
                        identifier: CycleHealthKitMapping.menstrualFlow
                    )
                    #expect(writes.map(\.date) == ["2026-09-20"], "logged in \(loggedIn.identifier), profile \(profile.identifier)")
                    #expect(writes.first?.externalId == "cycle-hk:2026-09-20")
                }
            }
        }

        @Test("A point-in-time sample is keyed on the account's day, not the phone's")
        func pointSampleUsesProfileDay() async throws {
            // 2026-06-19T03:00Z is still 2026-06-18 in Los Angeles and already
            // 2026-06-19 in Tokyo. One device zone cannot give both answers.
            let instant = try #require(ISO8601DateFormatter().date(from: "2026-06-19T03:00:00Z"))
            for (profile, day) in try [(zone("America/Los_Angeles"), "2026-06-18"), (zone("Asia/Tokyo"), "2026-06-19")] {
                let importer = try makeImporter(profile: profile)
                let writes = await importer.buildWrites(
                    from: [flow(start: instant, end: instant)],
                    identifier: CycleHealthKitMapping.menstrualFlow
                )
                #expect(writes.map(\.date) == [day])
                #expect(writes.first?.externalId == "cycle-hk:\(day)")
            }
        }

        /// **Update path.** An install that imported before #115 holds rows keyed
        /// `cycle-hk:<device-zone start day>`. For the samples it actually has —
        /// Health-app whole-day entries imported on the phone they were logged on
        /// — the new key is the same string, whatever the account zone, so a
        /// re-import (anchor reset, reinstall, sign-in again) re-posts ids the
        /// server already holds and upserts in place instead of adding days.
        @Test("Ids minted by the old importer come out unchanged on a re-import")
        func legacyIdsStayStable() async throws {
            let berlin = try zone("Europe/Berlin")
            let days = ["2026-03-28", "2026-03-29", "2026-03-30", "2026-10-24", "2026-10-25", "2026-10-26"]
            let samples = try days.map { try wholeDayFlow(on: $0, loggedIn: berlin) }
            let legacyIds = Set(samples.map { "cycle-hk:" + legacyKey(start: $0.startDate, deviceZone: berlin) })
            #expect(legacyIds == Set(days.map { "cycle-hk:\($0)" }))

            for profile in try [berlin, zone("Europe/London"), zone("America/New_York"), zone("Asia/Dubai")] {
                let importer = try makeImporter(profile: profile)
                let writes = await importer.buildWrites(from: samples, identifier: CycleHealthKitMapping.menstrualFlow)
                #expect(Set(writes.compactMap(\.externalId)) == legacyIds, "profile \(profile.identifier)")
                #expect(writes.count == days.count)
            }
        }
    }

#endif

// swiftlint:enable force_unwrapping
