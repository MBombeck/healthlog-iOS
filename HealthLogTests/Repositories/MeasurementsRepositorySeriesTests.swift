import Foundation

// swiftlint:disable force_unwrapping
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// Locks the `kind=` query for `/api/measurements/series` to the camelCase
/// domain-keys the server's Zod schema expects (W2a-A2 Audit §2.2). Sending
/// `BLOOD_PRESSURE_SYS` etc. previously made every chart 422.
@Suite("MeasurementsRepository.series query keys", .serialized)
struct MeasurementsRepositorySeriesTests {
    private func makeRepo() throws -> (MeasurementsRepository, InMemoryKeychain) {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.1.0",
            buildNumber: "1"
        )
        let kc = InMemoryKeychain()
        let api = APIClient(environment: env, keychain: kc, sessionConfiguration: .mock())
        return try (MeasurementsRepository(api: api, outbox: OutboxQueue(inMemory: true)), kc)
    }

    private func emptySeriesPayload() -> Data {
        Data(#"""
        {"data":{"kind":"weight","points":[],"stats":{"mean":0,"min":0,"max":0,"stdDev":0,"count":0}}}
        """#.utf8)
    }

    @Test(
        "Each MetricKind sends the camelCase server key",
        arguments: [
            (MetricKind.weight, "weight"),
            (.bloodPressure, "bloodPressure"),
            (.pulse, "pulse"),
            (.glucose, "glucose"),
            (.bodyFat, "bodyFat"),
            (.bodyTemperature, "bodyTemperature"),
            (.spo2, "oxygenSaturation"),
            (.bodyWater, "totalBodyWater"),
            (.boneMass, "boneMass")
        ]
    )
    func kindKeyMapping(kind: MetricKind, expected: String) async throws {
        let (repo, _) = try makeRepo()
        let body = emptySeriesPayload()
        nonisolated(unsafe) var capturedKind: String?
        MockURLProtocol.handler = { req in
            let comps = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)
            capturedKind = comps?.queryItems?.first(where: { $0.name == "kind" })?.value
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        _ = try await repo.series(kind: kind, days: 7)
        #expect(capturedKind == expected)
        // Belt-and-suspenders: never the legacy Prisma enum value
        #expect(capturedKind?.contains("_") == false)
    }

    // MARK: - W-SERVER-SYNC — `.all` range carries the full span (cap raised to 3650)

    /// Server v1.5.5 raised its `days` cap from 365 to 3650, so the iOS `.all`
    /// range (`days=3650`) now reaches the wire unchanged — true all-time is
    /// restored. The interim 365 clamp (which trimmed "All data" to a year) is
    /// gone; `series(kind:days:)` forwards the full span.
    @Test("`.all` range (days=3650) carries the full span to the wire")
    func allRangeDaysForwardsFullSpan() async throws {
        let (repo, _) = try makeRepo()
        let body = emptySeriesPayload()
        nonisolated(unsafe) var capturedDays: String?
        MockURLProtocol.handler = { req in
            let comps = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)
            capturedDays = comps?.queryItems?.first(where: { $0.name == "days" })?.value
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        // 3650 is `ChartDetailStore.Range.all.rawValue` and now equals the cap.
        _ = try await repo.series(kind: .steps, days: 3650)
        #expect(capturedDays == String(MeasurementsRepository.serverDaysCap))
        #expect(capturedDays == "3650")
    }

    @Test("In-cap windows are forwarded unchanged")
    func inCapDaysForwardedUnchanged() async throws {
        let (repo, _) = try makeRepo()
        let body = emptySeriesPayload()
        nonisolated(unsafe) var capturedDays: String?
        MockURLProtocol.handler = { req in
            let comps = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)
            capturedDays = comps?.queryItems?.first(where: { $0.name == "days" })?.value
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        _ = try await repo.series(kind: .weight, days: 180)
        #expect(capturedDays == "180")
    }
}

/// W-SERVER-SYNC — pure `clampDays` boundary contract. Pins the days-cap math
/// without spinning up the actor / network. The server v1.5.5 cap is 3650, so
/// `.all` passes through unchanged; the clamp stays as a defensive ceiling.
@Suite("MeasurementsRepository.clampDays — server days-cap boundary")
struct MeasurementsRepositoryClampDaysTests {
    @Test("`.all` (3650) passes through at the cap")
    func allPassesThroughAtCap() {
        #expect(MeasurementsRepository.clampDays(3650) == MeasurementsRepository.serverDaysCap)
        #expect(MeasurementsRepository.clampDays(3650) == 3650)
    }

    @Test("Below-cap windows pass through; above-cap clamps down")
    func atOrBelowCapUnchanged() {
        #expect(MeasurementsRepository.clampDays(3650) == 3650)
        #expect(MeasurementsRepository.clampDays(3651) == 3650)
        #expect(MeasurementsRepository.clampDays(365) == 365)
        #expect(MeasurementsRepository.clampDays(180) == 180)
        #expect(MeasurementsRepository.clampDays(1) == 1)
    }

    @Test("Sub-minimum windows clamp up to 1")
    func belowMinimumClampsUp() {
        #expect(MeasurementsRepository.clampDays(0) == 1)
        #expect(MeasurementsRepository.clampDays(-7) == 1)
    }
}
