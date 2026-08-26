import Foundation

// swiftlint:disable force_unwrapping
import Testing

#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// **AUDIO fix — `AUDIO_EXPOSURE_EVENT` no longer decodes as `.sleep`.**
///
/// `audioExposureEvent` is an HK category/event type with NO chartable
/// `MetricKind` (`InsightsMetricTabStrip` documents it as deliberately
/// unchartable). The prior mapping `case .audioExposureEvent: .sleep` was a
/// sleeping lie: the day the server emits such a row it would land in the sleep
/// list + chart. `metricKind` is now `MetricKind?` and `toDomain()` is failable
/// — a `nil`-kind row is dropped like the tolerant decoder drops an unknown
/// type, never fabricated onto a foreign axis.
///
/// Real `APIClient` + `MockURLProtocol` for the integration arm (PROJECT_GUIDE.md
/// anti-pattern: no mock-server), so a schema drift would actually break it. The
/// suite is `.serialized` because the network assertion depends on the
/// process-global `MockURLProtocol.handler` (audit-v0162 H2).
@Suite("AUDIO_EXPOSURE_EVENT drop", .serialized)
struct AudioExposureEventDropTests {
    // MARK: - Unit: the nil-kind seam

    @Test("audioExposureEvent has no chartable MetricKind")
    func audioExposureEventKindIsNil() {
        #expect(ServerMeasurementType.audioExposureEvent.metricKind == nil)
    }

    @Test(
        "every other server type still maps to a non-nil MetricKind",
        arguments: ServerMeasurementType.allCases.filter { $0 != .audioExposureEvent }
    )
    func everyOtherTypeMapsToAKind(_ type: ServerMeasurementType) {
        #expect(
            type.metricKind != nil,
            "\(type.rawValue) unexpectedly maps to nil — only audioExposureEvent may be the non-chartable seam"
        )
    }

    // MARK: - Integration: the row drops, never reaches a kind list

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

    @Test("an AUDIO_EXPOSURE_EVENT row drops without a decode error and never appears in any kind list")
    func audioRowDropsFromEveryKindList() async throws {
        let repo = try makeRepo()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        // A mixed page: one non-chartable audio-event row + one real sleep row.
        // The sleep row carries the LIVE list unit (`minutes`, 432 → 7.2 h).
        let body = "{\"data\":{\"measurements\":[" +
            "{\"id\":\"audio-1\",\"type\":\"AUDIO_EXPOSURE_EVENT\",\"value\":1,\"measuredAt\":\"\(iso(now))\"}," +
            "{\"id\":\"sleep-1\",\"type\":\"SLEEP_DURATION\",\"value\":432,\"unit\":\"minutes\"," +
            "\"measuredAt\":\"\(iso(now.addingTimeInterval(-3600)))\"}]}}"
        let payload = Data(body.utf8)
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, payload)
        }

        // The whole list decodes (no reject) — the audio row is dropped, not the page.
        let all = try await repo.recent(limit: 100)
        #expect(all.count == 1, "The audio-event row must be dropped; only the sleep row survives.")
        #expect(all.first?.id == "sleep-1")
        #expect(all.first?.kind == .sleep)
        // The dropped row must NOT have been fabricated onto the sleep axis.
        #expect(all.allSatisfy { $0.id != "audio-1" })

        // The kind-scoped sleep list carries the real sleep row and nothing audio.
        let sleepRows = try await repo.recent(kind: .sleep, limit: 100)
        #expect(sleepRows.contains { $0.id == "sleep-1" })
        #expect(sleepRows.allSatisfy { $0.id != "audio-1" })
    }

    // MARK: - BP-merge regression: an audio row can't ghost a paired reading

    @Test("mergeBloodPressure yields one BP measurement and no ghost row from an audio row")
    func bpMergeDropsAudioRowNoGhost() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let sys = MeasurementWireDTO(id: "sys", type: .bloodPressureSystolic, value: 124, measuredAt: now)
        let dia = MeasurementWireDTO(id: "dia", type: .bloodPressureDiastolic, value: 78, measuredAt: now)
        let audio = MeasurementWireDTO(
            id: "audio",
            type: .audioExposureEvent,
            value: 1,
            measuredAt: now.addingTimeInterval(-3600)
        )

        let merged = MeasurementAggregator.mergeBloodPressure([sys, dia, audio])

        #expect(merged.count == 1, "One paired BP measurement; the audio row is dropped, never a ghost.")
        let bp = merged.first
        #expect(bp?.kind == .bloodPressure)
        #expect(bp?.value == .bloodPressure(systolic: 124, diastolic: 78))
        #expect(merged.allSatisfy { $0.id != "audio" })
    }
}
