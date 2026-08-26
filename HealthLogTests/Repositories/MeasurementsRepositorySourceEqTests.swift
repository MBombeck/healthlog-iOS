import Foundation

// swiftlint:disable force_unwrapping
import Testing

#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// v0.14.8 W3 — v1.15.13 adoption: the management-list source filter rides
/// the server (`GET /api/measurements?sourceEq=…`) instead of slicing the
/// recency-capped page client-side (RESEARCH-SERVER-PARITY A2). Pins:
///
///   1. The plain kind-scoped arm threads `sourceEq=<WIRE>` + `type=`.
///   2. The BP paired arm scopes BOTH type pages.
///   3. Cumulative kinds ride `groupBy=day` + `sourceEq`.
///   4. `source: nil` delegates to the canonical unfiltered path (no param).
///   5. An older deploy (422 on the filter) degrades to the global page with
///      an honest client-side slice.
@Suite("MeasurementsRepository — server-side sourceEq filter", .serialized)
struct MeasurementsRepositorySourceEqTests {
    private func makeRepo() throws -> MeasurementsRepository {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.1.0",
            buildNumber: "1"
        )
        let kc = InMemoryKeychain()
        let api = APIClient(environment: env, keychain: kc, sessionConfiguration: .mock())
        return try MeasurementsRepository(api: api, outbox: OutboxQueue(inMemory: true))
    }

    private func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    private struct WireRow {
        let id: String
        let type: String
        let value: Double
        let at: Date
        var source: String = "WITHINGS"
    }

    private func listPayload(rows: [WireRow]) -> Data {
        let items = rows.map { row in
            """
            {"id":"\(row.id)","type":"\(row.type)","value":\(row.value),\
            "measuredAt":"\(iso(row.at))","source":"\(row.source)"}
            """
        }
        return Data("{\"data\":{\"measurements\":[\(items.joined(separator: ","))]}}".utf8)
    }

    private static func queryValue(_ url: URL, _ name: String) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == name })?
            .value
    }

    /// Thread-safe URL recorder for asserting on every request the repo fired.
    private final class URLRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _urls: [URL] = []

        func record(_ url: URL) {
            lock.lock()
            defer { lock.unlock() }
            _urls.append(url)
        }

        var urls: [URL] {
            lock.lock()
            defer { lock.unlock() }
            return _urls
        }
    }

    @Test("kind-scoped page threads sourceEq + type onto the wire")
    func kindScopedCarriesSourceEq() async throws {
        let repo = try makeRepo()
        let recorder = URLRecorder()
        let t1 = Date(timeIntervalSince1970: 1_780_000_000)
        let page = listPayload(rows: [
            WireRow(id: "w-1", type: "WEIGHT", value: 82.4, at: t1)
        ])
        MockURLProtocol.handler = { req in
            let url = req.url!
            recorder.record(url)
            return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, page)
        }

        let rows = try await repo.recent(kind: .weight, source: .withings)

        #expect(rows.count == 1)
        #expect(rows.first?.source == .withings)
        let url = try #require(recorder.urls.first)
        #expect(url.path == "/api/measurements")
        #expect(Self.queryValue(url, "type") == "WEIGHT")
        #expect(Self.queryValue(url, "sourceEq") == "WITHINGS")
        #expect(Self.queryValue(url, "groupBy") == nil)
    }

    @Test("BP paired arm scopes BOTH type pages with sourceEq")
    func bloodPressurePairCarriesSourceEqOnBothPages() async throws {
        let repo = try makeRepo()
        let recorder = URLRecorder()
        let t1 = Date(timeIntervalSince1970: 1_780_000_000)
        let sysPage = listPayload(rows: [
            WireRow(id: "sys-1", type: "BLOOD_PRESSURE_SYS", value: 124, at: t1, source: "MANUAL")
        ])
        let diaPage = listPayload(rows: [
            WireRow(id: "dia-1", type: "BLOOD_PRESSURE_DIA", value: 82, at: t1, source: "MANUAL")
        ])
        MockURLProtocol.handler = { req in
            let url = req.url!
            recorder.record(url)
            let payload: Data = switch Self.queryValue(url, "type") {
            case "BLOOD_PRESSURE_SYS": sysPage
            case "BLOOD_PRESSURE_DIA": diaPage
            default: Data("{\"data\":{\"measurements\":[]}}".utf8)
            }
            return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, payload)
        }

        let rows = try await repo.recent(kind: .bloodPressure, source: .manual)

        #expect(rows.count == 1)
        guard case let .bloodPressure(sys, dia) = rows.first?.value else {
            Issue.record("merged row is not a BP pair")
            return
        }
        #expect(sys == 124)
        #expect(dia == 82)
        let typed = recorder.urls.filter { Self.queryValue($0, "type") != nil }
        #expect(typed.count == 2)
        #expect(typed.allSatisfy { Self.queryValue($0, "sourceEq") == "MANUAL" })
    }

    @Test("cumulative kind rides groupBy=day + sourceEq")
    func cumulativeKindRidesGroupByDayWithSourceEq() async throws {
        let repo = try makeRepo()
        let recorder = URLRecorder()
        let t1 = Date(timeIntervalSince1970: 1_780_000_000)
        let page = listPayload(rows: [
            WireRow(
                id: "day:ACTIVE_ENERGY_BURNED:2026-06-10",
                type: "ACTIVE_ENERGY_BURNED",
                value: 412,
                at: t1,
                source: "APPLE_HEALTH"
            )
        ])
        MockURLProtocol.handler = { req in
            let url = req.url!
            recorder.record(url)
            return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, page)
        }

        let rows = try await repo.recent(kind: .activeEnergy, source: .appleHealth)

        #expect(rows.count == 1)
        let url = try #require(recorder.urls.first)
        #expect(Self.queryValue(url, "type") == "ACTIVE_ENERGY_BURNED")
        #expect(Self.queryValue(url, "groupBy") == "day")
        #expect(Self.queryValue(url, "sourceEq") == "APPLE_HEALTH")
    }

    @Test("source: nil delegates to the unfiltered path — no sourceEq param")
    func nilSourceOmitsParam() async throws {
        let repo = try makeRepo()
        let recorder = URLRecorder()
        let t1 = Date(timeIntervalSince1970: 1_780_000_000)
        let page = listPayload(rows: [
            WireRow(id: "w-1", type: "WEIGHT", value: 82.4, at: t1)
        ])
        MockURLProtocol.handler = { req in
            let url = req.url!
            recorder.record(url)
            return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, page)
        }

        _ = try await repo.recent(kind: .weight, source: nil)

        let url = try #require(recorder.urls.first)
        #expect(Self.queryValue(url, "sourceEq") == nil)
    }

    @Test("older deploy (422 on filter) degrades to global page + client slice")
    func filterRejectionFallsBackToClientSlice() async throws {
        let repo = try makeRepo()
        let t1 = Date(timeIntervalSince1970: 1_780_000_000)
        let globalPage = listPayload(rows: [
            WireRow(id: "w-1", type: "WEIGHT", value: 82.4, at: t1, source: "WITHINGS"),
            WireRow(id: "w-2", type: "WEIGHT", value: 83.1, at: t1.addingTimeInterval(-3600), source: "MANUAL")
        ])
        MockURLProtocol.handler = { req in
            let url = req.url!
            if Self.queryValue(url, "sourceEq") != nil {
                return (HTTPURLResponse(url: url, statusCode: 422, httpVersion: nil, headerFields: nil)!, Data())
            }
            return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, globalPage)
        }

        let rows = try await repo.recent(kind: .weight, source: .withings)

        #expect(rows.count == 1)
        #expect(rows.first?.id == "w-1")
        #expect(rows.allSatisfy { $0.source == .withings })
    }
}

// swiftlint:enable force_unwrapping
