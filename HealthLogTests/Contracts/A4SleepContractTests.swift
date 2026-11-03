// App-target symbols (`SleepHypnogramScreen`, `SleepNightSplit.breakdownLine`)
// are not in the SPM library; the SPM test build skips the file.
#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Synchronization
    import Testing

    // swiftlint:disable force_unwrapping

    /// **A4 (iOS 1.4) — sleep against server v1.43.10 (#146, #145).**
    ///
    /// Shapes from `docs/api/openapi.yaml` at tag `v1.43.10`:
    /// `MeasurementResource` (`mainAsleepMinutes` int or null, `napCount`,
    /// `napAsleepMinutes`, `dayKey`), `ListMeasurementsMeta` (`total`, `limit`,
    /// `offset`, `groupBy: night`) and the `/api/measurements` description ("a
    /// sleep page holds at most 1000 nights, and `meta.limit` echoes the value
    /// applied"); `/api/sleep/night` ("with a `date`, a nap-only day still
    /// answers `main: null` plus `naps`").
    @Suite("A4: sleep night, naps and pages (server v1.43.10)", .serialized, .mockURLSession)
    struct A4SleepContractTests {
        private func makeAPI() -> APIClient {
            let env = AppEnvironment(
                baseURL: URL(string: "https://test.healthlog.local")!,
                bundleID: "dev.healthlog.app",
                appVersion: "1.4.0",
                buildNumber: "1"
            )
            let keychain = InMemoryKeychain()
            try? keychain.setString("token", forKey: KeychainKey.authToken)
            return APIClient(environment: env, keychain: keychain, sessionConfiguration: .mock())
        }

        private static func ok(_ request: URLRequest, _ json: String) -> (HTTPURLResponse, Data?) {
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
        }

        /// One per-night row as `GET /api/measurements?type=SLEEP_DURATION`
        /// sends it since v1.43.7 (`value` = night plus naps, in minutes).
        static func sleepRow(day: String, value: Int, main: String, naps: Int, napMinutes: Int) -> String {
            """
            {"id":"sleep:\(day)","type":"SLEEP_DURATION","value":\(value),"unit":"minutes",
             "measuredAt":"\(day)T05:40:00.000Z","source":"APPLE_HEALTH","notes":null,"externalId":null,
             "syncVersion":1,"updatedAt":"\(day)T06:00:00.000Z","dayKey":"\(day)",
             "mainAsleepMinutes":\(main),"napCount":\(naps),"napAsleepMinutes":\(napMinutes)}
            """
        }

        static func page(_ rows: [String], total: Int, limit: Int, offset: Int) -> String {
            """
            {"data":{"measurements":[\(rows.joined(separator: ","))],
             "meta":{"total":\(total),"limit":\(limit),"offset":\(offset),"groupBy":"night"}},"error":null}
            """
        }

        // MARK: - The row

        @Test("a sleep row keeps the day's total and carries its night and naps as sent")
        func sleepRowSplit() throws {
            let json = Self.sleepRow(day: "2026-10-20", value: 470, main: "430", naps: 1, napMinutes: 40)
            let wire = try JSONDecoder.hlDefault.decode(MeasurementWireDTO.self, from: Data(json.utf8))
            let row = try #require(wire.toDomain())
            #expect(row.kind == .sleep)
            #expect(row.value == .scalar(470.0 / 60.0), "the headline stays the server's total")
            #expect(row.sleepSplit == SleepNightSplit(mainAsleepMinutes: 430, napCount: 1, napAsleepMinutes: 40))
            #expect(row.sleepSplit?.hasNaps == true)
            #expect(row.sleepSplit?.isNapsOnly == false)
        }

        @Test("a day of naps alone: main null, the total is the naps")
        func napsOnlyRow() throws {
            let json = Self.sleepRow(day: "2026-10-19", value: 35, main: "null", naps: 1, napMinutes: 35)
            let row = try #require(try JSONDecoder.hlDefault.decode(MeasurementWireDTO.self, from: Data(json.utf8)).toDomain())
            #expect(row.sleepSplit?.mainAsleepMinutes == nil)
            #expect(row.sleepSplit?.isNapsOnly == true)
        }

        @Test("an older server's row, and every other type, carry no split")
        func noSplitWithoutFields() throws {
            let old = #"""
            {"id":"sleep:2026-10-18","type":"SLEEP_DURATION","value":420,"unit":"minutes",
             "measuredAt":"2026-10-18T05:40:00.000Z","source":"APPLE_HEALTH"}
            """#
            #expect(try JSONDecoder.hlDefault.decode(MeasurementWireDTO.self, from: Data(old.utf8)).toDomain()?.sleepSplit == nil)
            let weight = #"""
            {"id":"w1","type":"WEIGHT","value":80,"unit":"kg","measuredAt":"2026-10-18T05:40:00.000Z",
             "source":"MANUAL","napCount":2}
            """#
            #expect(try JSONDecoder.hlDefault.decode(MeasurementWireDTO.self, from: Data(weight.utf8)).toDomain()?.sleepSplit == nil)
        }

        @Test("the split survives the SWR cache round trip; an old cache entry reads as no split")
        func cacheRoundTrip() throws {
            let json = Self.sleepRow(day: "2026-10-20", value: 470, main: "430", naps: 1, napMinutes: 40)
            let row = try #require(try JSONDecoder.hlDefault.decode(MeasurementWireDTO.self, from: Data(json.utf8)).toDomain())
            let cached = try JSONEncoder().encode([row])
            #expect(try JSONDecoder().decode([HealthLog.Measurement].self, from: cached) == [row])
            let legacy = HealthLog.Measurement(id: "m1", kind: .sleep, recordedAt: Date(timeIntervalSince1970: 0), value: .scalar(7))
            let legacyData = try JSONEncoder().encode([legacy])
            #expect(try JSONDecoder().decode([HealthLog.Measurement].self, from: legacyData).first?.sleepSplit == nil)
        }

        // MARK: - What the list and the metric page say

        @Test("the caption names night and naps only on a day with naps")
        func breakdownLine() {
            #expect(SleepNightSplit(mainAsleepMinutes: 430, napCount: 0, napAsleepMinutes: 0).breakdownLine == nil)
            let both = SleepNightSplit(mainAsleepMinutes: 430, napCount: 1, napAsleepMinutes: 40)
            let night = SleepDurationFormat.hoursMinutes(430)
            let naps = SleepDurationFormat.hoursMinutes(40)
            #expect(both.breakdownLine == String(localized: "sleep.split.nightAndNaps \(night) \(naps)"))
            let napsOnly = SleepNightSplit(mainAsleepMinutes: nil, napCount: 2, napAsleepMinutes: 55)
            #expect(napsOnly.breakdownLine == String(localized: "sleep.split.napsOnly"))
            for line in [both.breakdownLine, napsOnly.breakdownLine].compactMap(\.self) {
                for glyph in ["\u{00B7}", "\u{2014}", "\u{2013}", "\u{2192}"] {
                    #expect(!line.contains(glyph), "\(line)")
                }
            }
        }

        @Test("the Today tile is just Sleep: no 'Last night' beside a total that includes naps")
        func todayTileLabel() {
            #expect(MetricKind.sleep.descriptor.secondaryHint == nil)
        }

        // MARK: - Hypnogram

        static func session(night: String, start: String, end: String, asleep: Int) -> String {
            """
            {"night":"\(night)","source":"APPLE_HEALTH","start":"\(start)","end":"\(end)",
             "asleepMinutes":\(asleep),"inBedMinutes":\(asleep),"awakeMinutes":0,"awakenings":0,
             "stages":{},"segments":[],"reconstructed":false}
            """
        }

        @Test("a date with naps but no main night shows the naps, not 'no sleep data'")
        func hypnogramNapsOnly() throws {
            let nap = Self.session(night: "2026-10-19", start: "2026-10-19T12:30:00Z", end: "2026-10-19T13:05:00Z", asleep: 35)
            let json = #"{"main":null,"naps":[\#(nap)]}"#
            let night = try JSONDecoder.hlDefault.decode(SleepNightDTO.self, from: Data(json.utf8))
            #expect(SleepHypnogramScreen.content(for: night, isLoading: false) == .napsOnly)
            // Still loading over the cached naps: they stay on screen.
            #expect(SleepHypnogramScreen.content(for: night, isLoading: true) == .napsOnly)
            #expect(SleepHypnogramScreen.content(for: SleepNightDTO(main: nil, naps: []), isLoading: false) == .empty)
            #expect(SleepHypnogramScreen.content(for: nil, isLoading: true) == .loading)
            // An account that has only ever napped still gets a navigation anchor.
            #expect(SleepHypnogramScreen.anchorDayKey(for: night) == "2026-10-19")
        }

        @Test("a main night renders as before and anchors the navigation")
        func hypnogramMainNight() throws {
            let main = Self.session(night: "2026-10-20", start: "2026-10-19T22:30:00Z", end: "2026-10-20T05:40:00Z", asleep: 410)
            let night = try JSONDecoder.hlDefault.decode(SleepNightDTO.self, from: Data(#"{"main":\#(main),"naps":[]}"#.utf8))
            let session = try #require(night.main)
            #expect(SleepHypnogramScreen.content(for: night, isLoading: false) == .night(session))
            #expect(SleepHypnogramScreen.anchorDayKey(for: night) == "2026-10-20")
        }

        // MARK: - More than one page of nights

        @Test("when the server applies a smaller sleep page, the read goes on with offset")
        func sleepPaging() async throws {
            let offsets = Mutex<[String?]>([])
            MockURLProtocol.install { req in
                let items = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
                let offset = items.first { $0.name == "offset" }?.value
                offsets.withLock { $0.append(offset) }
                #expect(items.first { $0.name == "type" }?.value == "SLEEP_DURATION")
                let rows: [String] = switch offset {
                case nil: ["2026-10-20", "2026-10-19"]
                case "2": ["2026-10-18", "2026-10-17"]
                default: ["2026-10-16"]
                }
                let json = Self.page(
                    rows.map { Self.sleepRow(day: $0, value: 420, main: "420", naps: 0, napMinutes: 0) },
                    total: 5, limit: 2, offset: Int(offset ?? "0") ?? 0
                )
                return Self.ok(req, json)
            }
            let repo = try MeasurementsRepository(api: makeAPI(), outbox: OutboxQueue(inMemory: true))
            let nights = try await repo.recent(kind: .sleep, limit: 5)
            #expect(nights.count == 5)
            #expect(offsets.withLock { $0 } == [nil, "2", "4"])
            #expect(Set(nights.map(\.id)).count == 5)
        }

        @Test("a page served in full is one request, as before")
        func fullPageIsOneRequest() async throws {
            let calls = Mutex(0)
            MockURLProtocol.install { req in
                calls.withLock { $0 += 1 }
                let rows = ["2026-10-20", "2026-10-19"].map { Self.sleepRow(day: $0, value: 420, main: "420", naps: 0, napMinutes: 0) }
                return Self.ok(req, Self.page(rows, total: 2, limit: 400, offset: 0))
            }
            let repo = try MeasurementsRepository(api: makeAPI(), outbox: OutboxQueue(inMemory: true))
            let nights = try await repo.recent(kind: .sleep, limit: 400)
            #expect(nights.count == 2)
            #expect(calls.withLock { $0 } == 1)
        }
    }
#endif
