import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// Locks the wire contract for the two ECG reads (server v1.28.50,
/// `src/app/api/insights/ecg/route.ts` + `…/[id]/route.ts`).
///
/// Covers:
/// - list decode against the REAL route shape, including a `classification:null`
///   row and a `hasWaveform:false` `ts-`fallback row
/// - the empty `hasRecordings:false` shape decodes cleanly → surface gate off
/// - `403 MODULE_DISABLED`, `403 assistant.disabled.insightStatus` and `404`
///   → `nil` (the ECG surface hides; never an error)
/// - an unknown classification literal survives as `.unknown`, verbatim
/// - the device verdict, never a HealthLog verdict: only IRREGULAR /
///   INCONCLUSIVE route to the clinician note
/// - detail decode (samples + decimated) and detail `404` → `nil`
/// - `recordedAt` ISO-8601 decode through the APIClient's date strategy
@Suite("ECG — wire contract + double gating", .serialized)
struct EcgRepositoryTests {
    @Test("ECG ingest, list and detail routes share the pinned canonical base")
    func canonicalRoutes() {
        #expect(HealthIngestRoute.ecgIngest == "/api/insights/ecg")
        #expect(HealthIngestRoute.ecgList == HealthIngestRoute.ecgIngest)
        #expect(HealthIngestRoute.ecgDetail(id: "ecg-42") == "/api/insights/ecg/ecg-42")
    }

    private func makeAPI() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.14.1",
            buildNumber: "1"
        )
        return APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
    }

    private func respond(_ json: String, status: Int = 200) {
        let body = Data(json.utf8)
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, body)
        }
    }

    // MARK: - v1.37.3 ingest

    @Test("uploadRecording — exact pinned request, stable identity, and no idempotency header")
    func ingestRequestMatchesPinnedFixture() async throws {
        let fixture = try Self.loadV1373Fixture()
        let expectedRequest = try #require(fixture["request"] as? [String: Any])
        let responses = try #require(fixture["responses"] as? [String: [String: Any]])
        let inserted = try #require(responses["inserted"])
        let payload = try Self.payload(from: expectedRequest)
        let recorder = EcgRequestRecorder()
        let responseBody = try JSONSerialization.data(withJSONObject: inserted)
        MockURLProtocol.handler = { request in
            recorder.record(request)
            return (
                HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!,
                responseBody
            )
        }

        let response = try await EcgRepository(api: makeAPI()).uploadRecording(payload)

        #expect(response.status == .inserted)
        #expect(recorder.lastPath == HealthIngestRoute.ecgIngest)
        #expect(recorder.lastIdempotencyKey == nil)
        let actualRequest = try #require(recorder.lastJSON())
        #expect(NSDictionary(dictionary: actualRequest).isEqual(to: expectedRequest))
        #expect(actualRequest["externalRecordingId"] as? String == payload.externalRecordingId)
        #expect(actualRequest["source"] as? String == EcgIngestRequestDTO.appleHealthSource)
    }

    @Test(
        "uploadRecording — v1.37.3 status/code pairs decode with additive response fields",
        arguments: [("inserted", 201), ("updated", 200), ("duplicate", 200)]
    )
    func ingestResponsesMatchPinnedFixture(name: String, statusCode: Int) async throws {
        let fixture = try Self.loadV1373Fixture()
        let request = try #require(fixture["request"] as? [String: Any])
        let responses = try #require(fixture["responses"] as? [String: [String: Any]])
        var response = try #require(responses[name])
        var data = try #require(response["data"] as? [String: Any])
        data["futureServerField"] = ["ignored": true]
        response["data"] = data
        response["futureEnvelopeField"] = "ignored"
        let responseBody = try JSONSerialization.data(withJSONObject: response)
        MockURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!,
                responseBody
            )
        }

        let decoded = try await EcgRepository(api: makeAPI()).uploadRecording(Self.payload(from: request))

        #expect(decoded.status.rawValue == name)
        #expect(decoded.sampleCount == 3)
    }

    @Test("uploadRecording — refuses more than 32,768 samples before network I/O")
    func ingestSampleLimitFailsClosed() async {
        #expect(EcgIngestRequestDTO.maxSamples == 32768)
        let recorder = EcgRequestRecorder()
        MockURLProtocol.handler = { request in
            recorder.record(request)
            return (
                HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!,
                Data(#"{"data":{"id":"row","status":"inserted"},"error":null}"#.utf8)
            )
        }
        let payload = EcgIngestRequestDTO(
            externalRecordingId: "fixture-over-sample-limit",
            recordedAt: Date(timeIntervalSince1970: 978_404_645),
            samplingFrequency: 512,
            samples: Array(repeating: 0, count: EcgIngestRequestDTO.maxSamples + 1),
            lead: "I",
            averageHeartRate: 77,
            classification: .notDetected
        )

        await #expect(throws: HLError.self) {
            _ = try await EcgRepository(api: makeAPI()).uploadRecording(payload)
        }
        #expect(recorder.isEmpty)
    }

    @Test("uploadRecording — accepts exactly 32,768 samples")
    func ingestSampleLimitIsInclusive() async throws {
        #expect(EcgIngestRequestDTO.maxSamples == 32768)
        let fixture = try Self.loadV1373Fixture()
        let responses = try #require(fixture["responses"] as? [String: [String: Any]])
        let inserted = try #require(responses["inserted"])
        let responseBody = try JSONSerialization.data(withJSONObject: inserted)
        let recorder = EcgRequestRecorder()
        MockURLProtocol.handler = { request in
            recorder.record(request)
            return (
                HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!,
                responseBody
            )
        }
        let payload = EcgIngestRequestDTO(
            externalRecordingId: "fixture-at-sample-limit",
            recordedAt: Date(timeIntervalSince1970: 978_404_645),
            samplingFrequency: 512,
            samples: Array(repeating: 0, count: 32768),
            lead: "I",
            averageHeartRate: 77,
            classification: .notDetected
        )

        _ = try await EcgRepository(api: makeAPI()).uploadRecording(payload)

        #expect(recorder.count == 1)
    }

    @Test("uploadRecording — refuses a body over 2 MB before network I/O")
    func ingestBodyLimitFailsClosed() async {
        #expect(EcgIngestRequestDTO.maxBodyBytes == 2 * 1024 * 1024)
        let recorder = EcgRequestRecorder()
        MockURLProtocol.handler = { request in
            recorder.record(request)
            return (
                HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!,
                Data(#"{"data":{"id":"row","status":"inserted"},"error":null}"#.utf8)
            )
        }
        let payload = EcgIngestRequestDTO(
            externalRecordingId: String(repeating: "x", count: EcgIngestRequestDTO.maxBodyBytes),
            recordedAt: Date(timeIntervalSince1970: 978_404_645),
            samplingFrequency: 512,
            samples: [0],
            lead: "I",
            averageHeartRate: 77,
            classification: .notDetected
        )

        await #expect(throws: HLError.self) {
            _ = try await EcgRepository(api: makeAPI()).uploadRecording(payload)
        }
        #expect(recorder.isEmpty)
    }

    @Test("uploadRecording — accepts an encoded body of exactly 2 MB")
    func ingestBodyLimitIsInclusive() async throws {
        let releasedLimit = 2 * 1024 * 1024
        #expect(EcgIngestRequestDTO.maxBodyBytes == releasedLimit)
        let fixture = try Self.loadV1373Fixture()
        let responses = try #require(fixture["responses"] as? [String: [String: Any]])
        let inserted = try #require(responses["inserted"])
        let responseBody = try JSONSerialization.data(withJSONObject: inserted)
        let payload = try Self.payload(encodedSize: releasedLimit)
        let recorder = EcgRequestRecorder()
        MockURLProtocol.handler = { request in
            recorder.record(request)
            return (
                HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!,
                responseBody
            )
        }

        _ = try await EcgRepository(api: makeAPI()).uploadRecording(payload)

        #expect(recorder.count == 1)
    }

    // MARK: - List

    @Test("fetchList — decodes the real route shape (verdicts verbatim)")
    func listDecode() async throws {
        let repo = EcgRepository(api: makeAPI())
        respond(#"""
        {"data":{
          "recordings":[
            {"id":"ecg-1","recordedAt":"2026-01-15T08:30:00.000Z","durationSeconds":30,
             "samplingFrequency":300,"sampleCount":9000,"averageHeartRate":62,"lead":"I",
             "classification":"NOT_DETECTED","source":"WITHINGS","hasWaveform":true},
            {"id":"ecg-2","recordedAt":"2026-01-10T19:02:00.000Z","durationSeconds":30,
             "samplingFrequency":300,"sampleCount":9000,"averageHeartRate":81,"lead":"I",
             "classification":"IRREGULAR","source":"WITHINGS","hasWaveform":true},
            {"id":"ecg-3","recordedAt":"2025-12-24T07:00:00.000Z","durationSeconds":null,
             "samplingFrequency":null,"sampleCount":0,"averageHeartRate":null,"lead":null,
             "classification":null,"source":"WITHINGS","hasWaveform":false}
          ],
          "hasRecordings":true
        },"error":null}
        """#)
        let dto = try #require(try await repo.fetchList())
        #expect(dto.hasRecordings)
        #expect(dto.recordings.count == 3)
        #expect(dto.recordings[0].classification == "NOT_DETECTED")
        #expect(dto.recordings[0].verdict == .notDetected)
        #expect(dto.recordings[1].verdict == .irregular)
        // A `ts-` fallback event: verdict-less, sample-less, not openable.
        #expect(dto.recordings[2].verdict == .none)
        #expect(!dto.recordings[2].hasWaveform)
        #expect(dto.recordings[2].durationSeconds == nil)
        #expect(dto.recordings[2].lead == nil)
        // The list arrives newest-first; `latest` must not re-sort it.
        #expect(dto.latest?.id == "ecg-1")
    }

    @Test("fetchList — recordedAt decodes as a real instant (ISO 8601)")
    func recordedAtDecode() async throws {
        let repo = EcgRepository(api: makeAPI())
        respond(#"""
        {"data":{"recordings":[
          {"id":"ecg-1","recordedAt":"2026-01-15T08:30:00.000Z","durationSeconds":30,
           "samplingFrequency":300,"sampleCount":9000,"averageHeartRate":62,"lead":"I",
           "classification":"NOT_DETECTED","source":"WITHINGS","hasWaveform":true}
        ],"hasRecordings":true},"error":null}
        """#)
        let dto = try #require(try await repo.fetchList())
        let expected = Date(timeIntervalSince1970: 1_768_465_800) // 2026-01-15T08:30:00Z
        #expect(abs(dto.recordings[0].recordedAt.timeIntervalSince(expected)) < 1)
    }

    @Test("fetchList — empty hasRecordings:false decodes; the surface gate is OFF")
    func emptyListGatesSurfaceOff() async throws {
        let repo = EcgRepository(api: makeAPI())
        respond(#"{"data":{"recordings":[],"hasRecordings":false},"error":null}"#)
        let dto = try #require(try await repo.fetchList())
        #expect(!dto.hasRecordings)
        #expect(dto.recordings.isEmpty)
        #expect(dto.latest == nil)
    }

    @Test("fetchList — 403 MODULE_DISABLED → nil (no pill, no page, no error)")
    func moduleDisabledIsNil() async throws {
        let repo = EcgRepository(api: makeAPI())
        respond(#"{"data":null,"error":{"message":"Module disabled","code":"MODULE_DISABLED"}}"#, status: 403)
        #expect(try await repo.fetchList() == nil)
    }

    @Test("fetchList — 403 assistant.disabled.insightStatus → nil (the second gate)")
    func assistantSurfaceDisabledIsNil() async throws {
        let repo = EcgRepository(api: makeAPI())
        respond(
            #"{"data":null,"error":{"message":"Assistant surface disabled","code":"assistant.disabled.insightStatus"}}"#,
            status: 403
        )
        #expect(try await repo.fetchList() == nil)
    }

    @Test("fetchList — 404 (route not deployed) → nil")
    func listRouteAbsentIsNil() async throws {
        let repo = EcgRepository(api: makeAPI())
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
        }
        #expect(try await repo.fetchList() == nil)
    }

    // MARK: - Tolerant classification

    @Test("an unknown classification survives verbatim — the row is never lost")
    func unknownClassificationTolerated() async throws {
        let repo = EcgRepository(api: makeAPI())
        respond(#"""
        {"data":{"recordings":[
          {"id":"ecg-9","recordedAt":"2026-02-01T10:00:00.000Z","durationSeconds":30,
           "samplingFrequency":512,"sampleCount":15360,"averageHeartRate":58,"lead":"I",
           "classification":"SINUS_RHYTHM","source":"APPLE_HEALTH","hasWaveform":true}
        ],"hasRecordings":true},"error":null}
        """#)
        let dto = try #require(try await repo.fetchList())
        #expect(dto.recordings[0].verdict == .unknown("SINUS_RHYTHM"))
        #expect(dto.recordings[0].classification == "SINUS_RHYTHM")
    }

    @Test("only a non-normal DEVICE verdict routes to the clinician note")
    func clinicianNoteRouting() {
        #expect(EcgClassification(raw: "IRREGULAR").isNonNormalDeviceResult)
        #expect(EcgClassification(raw: "INCONCLUSIVE").isNonNormalDeviceResult)
        #expect(!EcgClassification(raw: "NOT_DETECTED").isNonNormalDeviceResult)
        #expect(!EcgClassification(raw: nil).isNonNormalDeviceResult)
        // An unrecognised literal is NOT escalated — HealthLog does not decide
        // what a device verdict it has never seen means.
        #expect(!EcgClassification(raw: "SINUS_RHYTHM").isNonNormalDeviceResult)
    }

    // MARK: - Detail

    @Test("fetchDetail — decodes the waveform payload (samples + decimated)")
    func detailDecode() async throws {
        let repo = EcgRepository(api: makeAPI())
        respond(#"""
        {"data":{"recordedAt":"2026-01-15T08:30:00.000Z","durationSeconds":30,
         "samplingFrequency":300,"averageHeartRate":62,"lead":"I",
         "classification":"NOT_DETECTED","source":"WITHINGS",
         "samples":[-12.5,0,42.25,-8,3],"decimated":true},"error":null}
        """#)
        let dto = try #require(try await repo.fetchDetail(id: "ecg-1"))
        #expect(dto.samples == [-12.5, 0, 42.25, -8, 3])
        #expect(dto.decimated)
        #expect(dto.verdict == .notDetected)
        #expect(dto.lead == "I")
    }

    @Test("fetchDetail — the id lands in the path")
    func detailPathWiring() async throws {
        let seen = SeenEcgURLs()
        let body = Data(#"""
        {"data":{"recordedAt":"2026-01-15T08:30:00.000Z","durationSeconds":30,
         "samplingFrequency":300,"averageHeartRate":62,"lead":"I",
         "classification":null,"source":"WITHINGS","samples":[0],"decimated":false},"error":null}
        """#.utf8)
        MockURLProtocol.handler = { req in
            seen.record(req.url?.absoluteString ?? "")
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let repo = EcgRepository(api: makeAPI())
        _ = try await repo.fetchDetail(id: "ecg-42")
        #expect(seen.all().first?.hasSuffix(HealthIngestRoute.ecgDetail(id: "ecg-42")) == true)
    }

    @Test("fetchDetail — 404 (foreign or unknown id) → nil, existence sealed")
    func detail404IsNil() async throws {
        let repo = EcgRepository(api: makeAPI())
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
        }
        #expect(try await repo.fetchDetail(id: "someone-elses-id") == nil)
    }

    private static func loadV1373Fixture(file: String = #filePath) throws -> [String: Any] {
        let repoRoot = URL(fileURLWithPath: file)
            .deletingLastPathComponent() // Repositories
            .deletingLastPathComponent() // HealthLogTests
            .deletingLastPathComponent() // repository root
        let fixtureURL = repoRoot
            .appendingPathComponent("HealthLogTests/Fixtures/Server/v1.37.3/ecg-ingest.json")
        let data = try Data(contentsOf: fixtureURL)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static func payload(from request: [String: Any]) throws -> EcgIngestRequestDTO {
        let formatter = ISO8601DateFormatter()
        let recordedAtString = try #require(request["recordedAt"] as? String)
        let recordedAt = try #require(formatter.date(from: recordedAtString))
        return try EcgIngestRequestDTO(
            externalRecordingId: #require(request["externalRecordingId"] as? String),
            recordedAt: recordedAt,
            samplingFrequency: #require(request["samplingFrequency"] as? Double),
            samples: #require(request["samples"] as? [NSNumber]).map(\.intValue),
            lead: #require(request["lead"] as? String),
            averageHeartRate: request["averageHeartRate"] as? Double,
            classification: EcgIngestClassification(
                rawValue: #require(request["classification"] as? String)
            )
        )
    }
}

private extension EcgRepositoryTests {
    static func payload(encodedSize: Int) throws -> EcgIngestRequestDTO {
        func makePayload(externalRecordingId: String) -> EcgIngestRequestDTO {
            EcgIngestRequestDTO(
                externalRecordingId: externalRecordingId,
                recordedAt: Date(timeIntervalSince1970: 978_404_645),
                samplingFrequency: 512,
                samples: [0],
                lead: "I",
                averageHeartRate: 77,
                classification: .notDetected
            )
        }

        let empty = makePayload(externalRecordingId: "")
        let fixedBytes = try JSONEncoder.hlDefault.encode(empty).count
        let payload = makePayload(externalRecordingId: String(repeating: "x", count: encodedSize - fixedBytes))
        let actualSize = try JSONEncoder.hlDefault.encode(payload).count
        #expect(actualSize == encodedSize)
        return payload
    }
}

/// Thread-safe URL recorder — the handler closure is `@Sendable` and runs off
/// the test's actor, so a plain array would be a data race.
private final class SeenEcgURLs: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [String] = []

    func record(_ url: String) {
        lock.lock()
        defer { lock.unlock() }
        urls.append(url)
    }

    func all() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return urls
    }
}

// swiftlint:enable force_unwrapping
