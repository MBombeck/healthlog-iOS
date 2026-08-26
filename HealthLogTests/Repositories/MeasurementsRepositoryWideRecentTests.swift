import Foundation

// swiftlint:disable force_unwrapping
import Testing

#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// v0.14.4 D2 — pins the data source the broadened `MeasurementListScreen`
/// fallback relies on. For a NON-series kind (`kindSupportsSeries == false`,
/// e.g. `.fatMass`/`.activeEnergy`/`.bmi`) the `/series` synthesis can't help —
/// the list now retries a WIDE `recent(kind:limit:)` so a long-dormant or
/// low-frequency kind surfaces its older rows instead of "keine Daten" while a
/// tap reveals the full list (the operator's recurring 30-day-card bug).
///
/// Real APIClient + URLProtocol-stubbed network (PROJECT_GUIDE.md anti-pattern: no
/// mock-server for these paths) so a schema drift would actually break the test.
@Suite("MeasurementsRepository wide recent fallback (D2)", .serialized)
struct MeasurementsRepositoryWideRecentTests {
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

    private func listPayload(type: String, value: Double, at: Date) -> Data {
        let body = "{\"data\":{\"measurements\":[" +
            "{\"id\":\"r1\",\"type\":\"\(type)\",\"value\":\(value),\"measuredAt\":\"\(iso(at))\"}]}}"
        return Data(body.utf8)
    }

    @Test("a non-series kind is gated out of the series path (so the list uses wide recent)")
    func nonSeriesKindGatedOut() {
        #expect(!ChartDetailStore.kindSupportsSeries(.fatMass))
        #expect(!ChartDetailStore.kindSupportsSeries(.activeEnergy))
        #expect(!ChartDetailStore.kindSupportsSeries(.bmi))
    }

    @Test("wide recent(kind:limit:) returns rows for a non-series kind when data exists")
    func wideRecentReturnsRowsForNonSeriesKind() async throws {
        let repo = try makeRepo()
        // A row from ~400 days ago — older than the default ~1y page window for a
        // dormant kind, but inside the wide ~10y window the D2 fallback requests.
        let old = Date(timeIntervalSince1970: 1_700_000_000).addingTimeInterval(-86400 * 400)
        let payload = listPayload(type: "FAT_MASS", value: 18.4, at: old)
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, payload)
        }
        let rows = try await repo.recent(kind: .fatMass, limit: 2000)
        #expect(!rows.isEmpty, "The wide recent fallback must surface the kind's existing rows.")
        #expect(rows.allSatisfy { $0.kind == .fatMass })
    }
}
