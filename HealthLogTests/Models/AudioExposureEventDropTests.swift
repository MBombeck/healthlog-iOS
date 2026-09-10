import Foundation

// swiftlint:disable force_unwrapping
import Testing

#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// **AUDIO fix, then audit B-4 — `AUDIO_EXPOSURE_EVENT` decodes as itself.**
///
/// The AUDIO fix replaced a sleeping lie (`case .audioExposureEvent: .sleep`,
/// which would have landed a fired notification in the sleep list and chart)
/// with a `nil` kind. That was honest about the axis and still wrong about the
/// row: `toDomain()` dropped every one of them, so the type stayed invisible
/// either way. Audit B-4 (2026-09-10) counted it — 76 of 77 server types known,
/// this the 77th — and gave it the kind its five sibling category events have
/// carried since Build 3 / item 3.3.
///
/// What both fixes share, and what this suite still locks: the row is never
/// fabricated onto a foreign axis. It is its own kind, categorical and
/// unitless, and it does not appear in any other kind's list.
///
/// Real `APIClient` + `MockURLProtocol` for the integration arm (PROJECT_GUIDE.md
/// anti-pattern: no mock-server), so a schema drift would actually break it. The
/// suite is `.serialized` because the network assertion depends on the
/// process-global `MockURLProtocol.handler` (audit-v0162 H2).
@Suite("AUDIO_EXPOSURE_EVENT", .serialized)
struct AudioExposureEventDropTests {
    // MARK: - Unit: the kind it maps to

    @Test("audioExposureEvent maps to its own kind, not to a foreign axis")
    func audioExposureEventKindIsItsOwn() {
        #expect(ServerMeasurementType.audioExposureEvent.metricKind == .audioExposureEvent)
        // The pre-AUDIO-fix bug, kept as a named assertion so it cannot return.
        #expect(ServerMeasurementType.audioExposureEvent.metricKind != .sleep)
        // Categorical like its five siblings: the value is always 1, so the
        // timestamp is the information and the unit label would be a lie.
        #expect(MetricKind.audioExposureEvent.isCategoricalEvent)
        #expect(MetricKind.audioExposureEvent.unit.isEmpty)
    }

    @Test(
        "every server type maps to a MetricKind — no type is dropped on the way in",
        arguments: ServerMeasurementType.allCases
    )
    func everyTypeMapsToAKind(_ type: ServerMeasurementType) {
        #expect(
            type.metricKind != nil,
            "\(type.rawValue) maps to nil — a nil kind means `toDomain()` discards the row"
        )
    }

    // MARK: - Integration: the row survives and stays out of foreign lists

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

    @Test("an AUDIO_EXPOSURE_EVENT row is kept and never appears in a foreign kind list")
    func audioRowSurvivesAndStaysOutOfForeignLists() async throws {
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

        // Audit B-4 — both rows survive. The page never rejected; what changed
        // is that the audio row is no longer thrown away on the way in.
        let all = try await repo.recent(limit: 100)
        #expect(all.count == 2, "Both rows must survive; the audio-event row is no longer discarded.")
        #expect(all.contains { $0.id == "audio-1" && $0.kind == .audioExposureEvent })
        #expect(all.contains { $0.id == "sleep-1" && $0.kind == .sleep })

        // ...and the audio row is on its OWN axis: the sleep list is unchanged.
        let sleepRows = try await repo.recent(kind: .sleep, limit: 100)
        #expect(sleepRows.contains { $0.id == "sleep-1" })
        #expect(sleepRows.allSatisfy { $0.id != "audio-1" })
    }

    // MARK: - BP-merge regression: an audio row can't ghost a paired reading

    @Test("mergeBloodPressure yields one BP measurement and the audio row beside it, never a ghost")
    func bpMergeKeepsAudioRowOutOfThePair() {
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

        #expect(merged.count == 2, "One paired BP measurement plus the audio row — the pair is not a ghost.")
        let bp = merged.first { $0.kind == .bloodPressure }
        #expect(bp?.value == .bloodPressure(systolic: 124, diastolic: 78))
        // The audio row rides beside the pair, never inside it.
        #expect(merged.contains { $0.id == "audio" && $0.kind == .audioExposureEvent })
    }
}
