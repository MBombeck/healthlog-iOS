import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// **1.5 BP-TOD (#161, server #1331, v1.47.0)** — blood pressure by time of
/// day: the wire contract of `GET /api/measurements/blood-pressure/time-of-day`,
/// the section's placement gate (server with and without the route), the
/// section state across range changes and failures, and the wording that turns
/// the server's figures into text without recomputing them.
@Suite("1.5 BP-TOD — blood pressure by time of day", .serialized, .mockURLSession)
struct BloodPressureTimeOfDayTests {
    private func makeAPI() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "1.5.0",
            buildNumber: "1"
        )
        return APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
    }

    /// The server's shape (`BloodPressureTimeOfDay`, OpenAPI v1.47.0): morning
    /// and evening above the floor, midday below it (means `null`), pulse only
    /// where it reached the floor too.
    static let fullBody = #"""
    {"data":{
      "days":30,
      "from":"2026-10-06T02:00:00.000Z",
      "to":"2026-11-04T22:59:59.999Z",
      "timeZone":"Europe/Berlin",
      "minReadings":3,
      "readingCount":21,
      "parts":[
        {"part":"morning","startHour":4,"endHour":12,"readingCount":11,"systolic":134,"diastolic":86,"pulseReadingCount":10,"pulse":66},
        {"part":"midday","startHour":12,"endHour":18,"readingCount":2,"systolic":null,"diastolic":null,"pulseReadingCount":2,"pulse":null},
        {"part":"evening","startHour":18,"endHour":4,"readingCount":8,"systolic":128,"diastolic":83,"pulseReadingCount":1,"pulse":null}
      ],
      "morningEveningDifference":{"systolic":6,"diastolic":3}
    },"error":null}
    """#

    private static func decode(_ json: String) throws -> BloodPressureTimeOfDay {
        try JSONDecoder.hlDefault.decode(Envelope.self, from: Data(json.utf8)).data
    }

    private struct Envelope: Decodable {
        let data: BloodPressureTimeOfDay
    }

    private static func summary(
        readingCount: Int = 21,
        difference: BloodPressureTimeOfDay.Difference? = nil,
        days: Int = 30
    ) -> BloodPressureTimeOfDay {
        BloodPressureTimeOfDay(
            days: days,
            timeZone: "Europe/Berlin",
            minReadings: 3,
            readingCount: readingCount,
            parts: [],
            morningEveningDifference: difference
        )
    }

    // MARK: - Wire contract

    @Test("decodes the server shape as given: means, counts, floor and difference")
    func decodesFullShape() throws {
        let dto = try Self.decode(Self.fullBody)
        #expect(dto.days == 30)
        #expect(dto.timeZone == "Europe/Berlin")
        #expect(dto.minReadings == 3)
        #expect(dto.readingCount == 21)
        #expect(dto.parts.map(\.part) == [.morning, .midday, .evening])
        let morning = dto.parts[0]
        #expect(morning.systolic == 134)
        #expect(morning.diastolic == 86)
        #expect(morning.readingCount == 11)
        #expect(morning.pulse == 66)
        #expect(morning.hasMean)
        // Below the floor: the server withholds the mean, the app keeps the count.
        let midday = dto.parts[1]
        #expect(midday.systolic == nil)
        #expect(midday.diastolic == nil)
        #expect(midday.readingCount == 2)
        #expect(!midday.hasMean)
        let evening = dto.parts[2]
        #expect(evening.startHour == 18)
        #expect(evening.endHour == 4)
        #expect(evening.pulse == nil)
        #expect(dto.morningEveningDifference == .init(systolic: 6, diastolic: 3))
        #expect(!dto.isEmpty)
    }

    @Test("difference null stays null; a zero difference is a value, not absence")
    func differenceNullAndZero() throws {
        let null = Self.fullBody.replacingOccurrences(
            of: #""morningEveningDifference":{"systolic":6,"diastolic":3}"#,
            with: #""morningEveningDifference":null"#
        )
        #expect(try Self.decode(null).morningEveningDifference == nil)
        let zero = Self.fullBody.replacingOccurrences(
            of: #""morningEveningDifference":{"systolic":6,"diastolic":3}"#,
            with: #""morningEveningDifference":{"systolic":0,"diastolic":0}"#
        )
        #expect(try Self.decode(zero).morningEveningDifference == .init(systolic: 0, diastolic: 0))
    }

    @Test("a part this build does not know is skipped, the rest of the card stays")
    func unknownPartSkipped() throws {
        let body = Self.fullBody.replacingOccurrences(of: #""part":"midday""#, with: #""part":"night""#)
        let dto = try Self.decode(body)
        #expect(dto.parts.map(\.part) == [.morning, .evening])
    }

    @Test("no paired reading in the window is the empty state")
    func emptyWindow() throws {
        let body = #"""
        {"data":{"days":7,"from":"2026-10-29T03:00:00.000Z","to":"2026-11-04T22:59:59.999Z","timeZone":"Europe/Berlin",
        "minReadings":3,"readingCount":0,"parts":[
        {"part":"morning","startHour":4,"endHour":12,"readingCount":0,"systolic":null,"diastolic":null,"pulseReadingCount":0,"pulse":null},
        {"part":"midday","startHour":12,"endHour":18,"readingCount":0,"systolic":null,"diastolic":null,"pulseReadingCount":0,"pulse":null},
        {"part":"evening","startHour":18,"endHour":4,"readingCount":0,"systolic":null,"diastolic":null,"pulseReadingCount":0,"pulse":null}],
        "morningEveningDifference":null},"error":null}
        """#
        let dto = try Self.decode(body)
        #expect(dto.isEmpty)
        #expect(dto.parts.count == 3)
    }

    @Test("the repository asks for the chart's range in days, clamped to the server bounds")
    func repositoryQuery() async throws {
        let repo = BloodPressureTimeOfDayRepository(api: makeAPI())
        let body = Data(Self.fullBody.utf8)
        let seen = LockedURLs()
        MockURLProtocol.install { req in
            seen.append(req.url!)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let dto = try await repo.fetch(days: 180)
        #expect(dto.readingCount == 21)
        _ = try await repo.fetch(days: 0)
        _ = try await repo.fetch(days: 9999)
        let urls = seen.all
        #expect(urls.count == 3)
        #expect(urls.allSatisfy { $0.path == "/api/measurements/blood-pressure/time-of-day" })
        let days = urls
            .compactMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "days" }?.value }
        #expect(days == ["180", "1", "3650"])
    }

    @Test("a server without the route answers 404, which the section reads as absent")
    func repositoryNotFound() async throws {
        let repo = BloodPressureTimeOfDayRepository(api: makeAPI())
        MockURLProtocol.install { req in
            (
                HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!,
                Data(#"{"data":null,"error":"Not found"}"#.utf8)
            )
        }
        await #expect(throws: (any Error).self) { _ = try await repo.fetch(days: 30) }
        let model = await BloodPressureTimeOfDayModel(repository: repo)
        await model.load(days: 30)
        #expect(await model.phase == .absent)
    }

    // MARK: - Placement gate (Regel 10)

    @Test("only on the blood pressure page of a paired server that has the route")
    func placementGate() throws {
        let defaults = try #require(UserDefaults(suiteName: "bp-tod-\(UUID().uuidString)"))
        // Unknown version: no.
        #expect(!BloodPressureTimeOfDaySection.isAvailable(for: .bloodPressure, hasServer: true, defaults: defaults))
        KnownServerVersion.record(ServerVersionInfo(version: "1.46.6"), defaults: defaults)
        #expect(!BloodPressureTimeOfDaySection.isAvailable(for: .bloodPressure, hasServer: true, defaults: defaults))
        KnownServerVersion.record(ServerVersionInfo(version: "1.47.0"), defaults: defaults)
        #expect(BloodPressureTimeOfDaySection.isAvailable(for: .bloodPressure, hasServer: true, defaults: defaults))
        KnownServerVersion.record(ServerVersionInfo(version: "1.48.2"), defaults: defaults)
        #expect(BloodPressureTimeOfDaySection.isAvailable(for: .bloodPressure, hasServer: true, defaults: defaults))
        // The observed form the view reads: the same answers from the raw value.
        #expect(!BloodPressureTimeOfDaySection.isAvailable(for: .bloodPressure, hasServer: true, serverVersion: nil))
        #expect(!BloodPressureTimeOfDaySection.isAvailable(for: .bloodPressure, hasServer: true, serverVersion: "1.46.9"))
        #expect(BloodPressureTimeOfDaySection.isAvailable(for: .bloodPressure, hasServer: true, serverVersion: "1.47.0"))
        // Not without a server, not on another page.
        #expect(!BloodPressureTimeOfDaySection.isAvailable(for: .bloodPressure, hasServer: false, defaults: defaults))
        #expect(!BloodPressureTimeOfDaySection.isAvailable(for: .pulse, hasServer: true, defaults: defaults))
        #expect(!BloodPressureTimeOfDaySection.isAvailable(for: .weight, hasServer: true, defaults: defaults))
    }

    // MARK: - Section state

    @Test("range change: the new range is read, a range read before paints at once")
    @MainActor
    func rangeChange() async {
        let asked = LockedInts()
        let model = BloodPressureTimeOfDayModel { days in
            asked.append(days)
            return Self.summary(readingCount: days, days: days)
        }
        #expect(model.phase == .loading)
        await model.load(days: 30)
        #expect(model.phase == .loaded(Self.summary(readingCount: 30, days: 30)))
        #expect(model.shownDays == 30)
        await model.load(days: 7)
        #expect(model.phase == .loaded(Self.summary(readingCount: 7, days: 7)))
        #expect(model.shownDays == 7)
        #expect(!model.isRefreshing)
        await model.load(days: 30)
        #expect(asked.all == [30, 7, 30])
        #expect(model.shownDays == 30)
    }

    @Test("refusal is the disabled card, a transport error the retry row, a held answer survives a failed re-read")
    @MainActor
    func failures() async {
        let refused = BloodPressureTimeOfDayModel { _ in
            throw HLError.server(status: 403, code: "sharing.client.access.denied", message: "")
        }
        await refused.load(days: 30)
        #expect(refused.phase == .disabled(nil))

        let moduleOff = BloodPressureTimeOfDayModel { _ in throw HLError.moduleDisabled("measurements") }
        await moduleOff.load(days: 30)
        #expect(moduleOff.phase == .disabled(nil))

        let broken = BloodPressureTimeOfDayModel { _ in throw HLError.offline }
        await broken.load(days: 30)
        #expect(broken.phase == .failed)

        let fail = LockedFlag()
        let flaky = BloodPressureTimeOfDayModel { days in
            if fail.value { throw HLError.server(status: 500, code: nil, message: "") }
            return Self.summary(days: days)
        }
        await flaky.load(days: 30)
        fail.set(true)
        await flaky.load(days: 30)
        #expect(flaky.phase == .loaded(Self.summary(days: 30)))
        // A range never read has nothing to hold: the retry row.
        await flaky.load(days: 7)
        #expect(flaky.phase == .failed)
        fail.set(false)
        await flaky.load(days: 7)
        #expect(flaky.phase == .loaded(Self.summary(days: 7)))
    }

    @Test("a cancelled read leaves the state for the next read")
    @MainActor
    func cancellation() async {
        let model = BloodPressureTimeOfDayModel { _ in throw CancellationError() }
        await model.load(days: 30)
        #expect(model.phase == .loading)
    }

    // MARK: - Wording (values as the server sends them)

    @Test("hour windows come from the server's hours; evening runs past midnight")
    func hourWindows() throws {
        let dto = try Self.decode(Self.fullBody)
        let morning = BloodPressureTimeOfDaySection.hours(dto.parts[0])
        #expect(morning.contains("04:00"))
        #expect(morning.contains("11:59"))
        let evening = BloodPressureTimeOfDaySection.hours(dto.parts[2])
        #expect(evening.contains("18:00"))
        // 01:15 belongs to the evening before: the window ends at 03:59.
        #expect(evening.contains("03:59"))
    }

    @Test("means and difference are the server's numbers; kPa only converts the unit")
    func figures() throws {
        let dto = try Self.decode(Self.fullBody)
        let mmHg = UnitPreferences.standard
        #expect(BloodPressureTimeOfDaySection.pair(dto.parts[0], units: mmHg) == "134/86")
        #expect(BloodPressureTimeOfDaySection.pair(dto.parts[1], units: mmHg) == nil)
        #expect(BloodPressureTimeOfDaySection.signed(6, units: mmHg) == "+6")
        #expect(BloodPressureTimeOfDaySection.signed(0, units: mmHg) == "0")
        let falling = BloodPressureTimeOfDaySection.signed(-4, units: mmHg)
        #expect(falling.contains("4") && !falling.contains("+") && falling != "4")
        let line = BloodPressureTimeOfDaySection.differenceLine(.init(systolic: 6, diastolic: 3), units: mmHg)
        #expect(line.contains("+6/+3 mmHg"))
        let zero = BloodPressureTimeOfDaySection.differenceLine(.init(systolic: 0, diastolic: 0), units: mmHg)
        #expect(zero.contains("0/0 mmHg"))

        let kPa = UnitPreferences(bloodPressure: .kPa)
        let pair = try #require(BloodPressureTimeOfDaySection.pair(dto.parts[0], units: kPa))
        // 134 mmHg = 17.9 kPa, 86 mmHg = 11.5 kPa (one decimal, locale separator).
        #expect(pair.contains("17") && pair.contains("9") && pair.contains("/11"))
        #expect(BloodPressureTimeOfDaySection.differenceLine(.init(systolic: 6, diastolic: 3), units: kPa).contains("kPa"))
    }

    @Test("reading counts and VoiceOver name every figure of a part")
    func readingsAndVoiceOver() throws {
        let dto = try Self.decode(Self.fullBody)
        #expect(BloodPressureTimeOfDaySection.readings(1) != BloodPressureTimeOfDaySection.readings(2))
        #expect(BloodPressureTimeOfDaySection.readings(11).contains("11"))
        let mmHg = UnitPreferences.standard
        let morning = BloodPressureTimeOfDaySection.spokenValue(dto.parts[0], units: mmHg)
        #expect(morning.contains("134") && morning.contains("86") && morning.contains("11") && morning.contains("66"))
        let midday = BloodPressureTimeOfDaySection.spokenValue(dto.parts[1], units: mmHg)
        #expect(midday.contains(String(localized: "insights.bpTimeOfDay.notEnough")))
        #expect(midday.contains("2"))
    }
}

// MARK: - Small thread-safe recorders

private final class LockedURLs: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    func append(_ url: URL) {
        lock.withLock { urls.append(url) }
    }

    var all: [URL] {
        lock.withLock { urls }
    }
}

private final class LockedInts: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int] = []
    func append(_ value: Int) {
        lock.withLock { values.append(value) }
    }

    var all: [Int] {
        lock.withLock { values }
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set(_ value: Bool) {
        lock.withLock { flag = value }
    }

    var value: Bool {
        lock.withLock { flag }
    }
}
