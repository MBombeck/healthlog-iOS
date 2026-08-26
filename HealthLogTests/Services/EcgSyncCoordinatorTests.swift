import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// **GH #74 / server v1.35.3 — the ECG upload path.**
///
/// Drives ``EcgSyncCoordinator`` over the **real** ``APIClient`` +
/// `MockURLProtocol` (PROJECT_GUIDE.md: no mock server, or schema drift goes unseen),
/// with a synthetic ``EcgRecordingSource`` in place of HealthKit — no real
/// health sample is ever constructed, and no waveform is ever logged.
///
/// `.serialized` — the suite installs the process-global `MockURLProtocol.handler`.
@Suite("EcgSyncCoordinator — Vertrag, Fehlerklassen, Anker", .serialized)
struct EcgSyncCoordinatorTests {
    // Fixtures + Doubles: `EcgSyncTestSupport.swift`.

    // MARK: - Wire contract

    @Test("POST /api/insights/ecg trägt exakt die acht Vertragsfelder — nichts mehr, nichts weniger")
    func payloadIsExactlyTheContract() async throws {
        let (api, kc) = EcgSyncTestSupport.makeClient()
        let recorder = EcgRequestRecorder()
        let reply = EcgSyncTestSupport.okResponse("inserted", code: 201)
        MockURLProtocol.handler = { req in
            if req.targets("/api/insights/ecg") { recorder.record(req) }
            return reply(req)
        }
        let source = FakeEcgSource(
            recordings: [EcgSyncTestSupport.recording()],
            volts: ["11111111-2222-3333-4444-555555555555": [0.000012, -0.000007, 0.000003]]
        )
        let summary = await EcgSyncTestSupport.makeCoordinator(api: api, keychain: kc, source: source).sync()

        #expect(summary.inserted == 1)
        #expect(recorder.count == 1)
        #expect(recorder.lastPath == "/api/insights/ecg")
        let body = try #require(recorder.lastJSON())

        // The body is `.strict()` server-side: ONE unknown field costs the whole
        // recording with a 422. So the key set is pinned exactly, not merely
        // spot-checked.
        #expect(
            Set(body.keys) == [
                "externalRecordingId", "recordedAt", "samplingFrequency",
                "samples", "lead", "averageHeartRate", "classification", "source"
            ]
        )
        // The two fields the server derives itself must NOT be sent.
        #expect(body["sampleCount"] == nil)
        #expect(body["durationSeconds"] == nil)

        #expect(body["externalRecordingId"] as? String == "11111111-2222-3333-4444-555555555555")
        #expect(body["source"] as? String == "APPLE_HEALTH")
        #expect(body["lead"] as? String == "I")
        #expect(body["classification"] as? String == "NOT_DETECTED")
        #expect(body["samplingFrequency"] as? Double == 512)
        // Volts in, integer microvolts out.
        let samples = try #require(body["samples"] as? [NSNumber]).map(\.intValue)
        #expect(samples == [12, -7, 3])
    }

    @Test("Kein Idempotency-Key — die Aufzeichnung trägt ihre Identität selbst")
    func noIdempotencyKeyHeader() async {
        let (api, kc) = EcgSyncTestSupport.makeClient()
        let recorder = EcgRequestRecorder()
        let reply = EcgSyncTestSupport.okResponse("inserted", code: 201)
        MockURLProtocol.handler = { req in
            if req.targets("/api/insights/ecg") { recorder.record(req) }
            return reply(req)
        }
        let source = FakeEcgSource(recordings: [EcgSyncTestSupport.recording()], volts: ["11111111-2222-3333-4444-555555555555": [0]])
        _ = await EcgSyncTestSupport.makeCoordinator(api: api, keychain: kc, source: source).sync()
        // The server states it does not evaluate one. Sending it anyway would be
        // header traffic asserting a contract that does not exist on this route.
        #expect(recorder.lastIdempotencyKey == nil)
    }

    @Test("Fehlende Herzfrequenz wird weggelassen, nicht erfunden")
    func absentHeartRateIsOmitted() async throws {
        let (api, kc) = EcgSyncTestSupport.makeClient()
        let recorder = EcgRequestRecorder()
        let reply = EcgSyncTestSupport.okResponse("inserted", code: 201)
        MockURLProtocol.handler = { req in
            if req.targets("/api/insights/ecg") { recorder.record(req) }
            return reply(req)
        }
        let source = FakeEcgSource(
            recordings: [EcgSyncTestSupport.recording(classification: nil, averageHeartRate: nil)],
            volts: ["11111111-2222-3333-4444-555555555555": [0.001]]
        )
        _ = await EcgSyncTestSupport.makeCoordinator(api: api, keychain: kc, source: source).sync()
        let body = try #require(recorder.lastJSON())
        #expect(body["averageHeartRate"] == nil, "kein Wert ist ehrlicher als ein erfundener")
        #expect(body["classification"] == nil, "kein Urteil ist ehrlicher als ein geratenes")
        #expect(Set(body.keys) == ["externalRecordingId", "recordedAt", "samplingFrequency", "samples", "lead", "source"])
    }

    // MARK: - All three statuses are success

    @Test(
        "inserted / updated / duplicate sind alle drei Erfolg",
        arguments: [("inserted", 201), ("updated", 200), ("duplicate", 200)]
    )
    func allThreeStatusesAreSuccess(status: String, code: Int) async {
        let (api, kc) = EcgSyncTestSupport.makeClient()
        let reply = EcgSyncTestSupport.okResponse(status, code: code)
        MockURLProtocol.handler = { reply($0) }
        let defaults = EcgSyncTestSupport.isolatedDefaults()
        let source = FakeEcgSource(recordings: [EcgSyncTestSupport.recording()], volts: ["11111111-2222-3333-4444-555555555555": [0]])
        let summary = await EcgSyncTestSupport.makeCoordinator(
            api: api,
            keychain: kc,
            source: source,
            defaultsProvider: defaults
        ).sync()
        #expect(summary.accepted == 1, "\(status) ist ein Erfolg")
        #expect(summary.skippedCount == 0)
        #expect(summary.stoppedBecause == nil)
        #expect(
            defaults().data(forKey: EcgSyncTestSupport.anchorKey) == Data("anchor".utf8),
            "only a released success may advance the cursor"
        )
    }

    // MARK: - One waveform at a time

    @Test("Nie mehr als eine Kurve gleichzeitig — gelesen, gesendet, fallengelassen")
    func oneWaveformAtATime() async {
        let (api, kc) = EcgSyncTestSupport.makeClient()
        let timeline = EventTimeline()
        let reply = EcgSyncTestSupport.okResponse("inserted", code: 201)
        MockURLProtocol.handler = { req in
            if req.targets("/api/insights/ecg") { timeline.append("post") }
            return reply(req)
        }
        let ids = ["a-1", "b-2", "c-3"]
        let source = FakeEcgSource(
            recordings: ids.map { EcgSyncTestSupport.recording(id: $0) },
            volts: Dictionary(uniqueKeysWithValues: ids.map { ($0, [0.001, 0.002, 0.003]) }),
            timeline: timeline
        )
        let summary = await EcgSyncTestSupport.makeCoordinator(api: api, keychain: kc, source: source).sync()

        #expect(summary.inserted == 3)
        // read → send → read → send → read → send. A batch read up front (which
        // is what "hold three waveforms" would look like) reads
        // volts,volts,volts,post,post,post and fails here.
        #expect(timeline.events == ["volts:a-1", "post", "volts:b-2", "post", "volts:c-3", "post"])
    }

    // MARK: - Gates

    @Test("Ohne Opt-in passiert nichts — auch keine HealthKit-Abfrage")
    func optInGate() async {
        let (api, kc) = EcgSyncTestSupport.makeClient()
        let recorder = EcgRequestRecorder()
        MockURLProtocol.handler = { req in
            if req.targets("/api/insights/ecg") { recorder.record(req) }
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }
        let source = FakeEcgSource(recordings: [EcgSyncTestSupport.recording()], volts: ["11111111-2222-3333-4444-555555555555": [0]])
        let summary = await EcgSyncTestSupport.makeCoordinator(api: api, keychain: kc, source: source, optedIn: false).sync()
        #expect(summary == .zero)
        #expect(source.fetchCount == 0, "kein Opt-in ⇒ kein Lesen der sensibelsten Fläche des Speichers")
        #expect(recorder.isEmpty)
    }

    @Test("Ohne Anmeldung passiert nichts")
    func authTokenGate() async {
        let (api, kc) = EcgSyncTestSupport.makeClient(token: nil)
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }
        let source = FakeEcgSource(recordings: [EcgSyncTestSupport.recording()], volts: ["11111111-2222-3333-4444-555555555555": [0]])
        let summary = await EcgSyncTestSupport.makeCoordinator(api: api, keychain: kc, source: source).sync()
        #expect(summary == .zero)
        #expect(source.fetchCount == 0)
    }

    @Test("Ohne das insights-Modul passiert nichts — dieselbe Schranke wie beim Lesen")
    func insightsModuleGate() async {
        let (api, kc) = EcgSyncTestSupport.makeClient()
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }
        let source = FakeEcgSource(recordings: [EcgSyncTestSupport.recording()], volts: ["11111111-2222-3333-4444-555555555555": [0]])
        let summary = await EcgSyncTestSupport.makeCoordinator(api: api, keychain: kc, source: source, moduleEnabled: false).sync()
        #expect(summary == .zero)
        #expect(source.fetchCount == 0)
    }

    @Test("Ein Accountwechsel während des HealthKit-Lesens darf nie unter Bs Bearer senden")
    func accountSwitchBeforeWireInvalidatesSweep() async throws {
        let (api, keychain) = EcgSyncTestSupport.makeClient(token: "bearer-A")
        try keychain.setString("user-A", forKey: KeychainKey.userID)
        let recorder = EcgRequestRecorder()
        let reply = EcgSyncTestSupport.okResponse("inserted", code: 201)
        MockURLProtocol.handler = { request in
            if request.targets("/api/insights/ecg") { recorder.record(request) }
            return reply(request)
        }
        let defaults = EcgSyncTestSupport.isolatedDefaults()
        let barrier = EcgVoltageBarrier()
        let source = FakeEcgSource(
            recordings: [EcgSyncTestSupport.recording()],
            volts: [EcgSyncTestSupport.defaultRecordingID: [0]],
            beforeVoltages: { await barrier.wait() }
        )
        let coordinator = EcgSyncTestSupport.makeCoordinator(
            api: api,
            keychain: keychain,
            source: source,
            defaultsProvider: defaults
        )
        let run = Task { await coordinator.sync() }
        await barrier.waitUntilEntered()

        try keychain.setString("user-B", forKey: KeychainKey.userID)
        try keychain.setString("bearer-B", forKey: KeychainKey.authToken)
        await barrier.release()
        let summary = await run.value

        #expect(recorder.isEmpty, "A's ECG must never reach the wire under B's bearer")
        #expect(summary.accepted == 0)
        #expect(summary.stoppedBecause == .transport)
        #expect(defaults().data(forKey: "hl.ecg.hk.anchor.user-A") == nil)
        #expect(defaults().data(forKey: "hl.ecg.hk.anchor.user-B") == nil)
    }

    @Test("Logout während des HealthKit-Lesens stoppt vor dem Draht")
    func logoutBeforeWireInvalidatesSweep() async throws {
        let (api, keychain) = EcgSyncTestSupport.makeClient(token: "bearer-A")
        try keychain.setString("user-A", forKey: KeychainKey.userID)
        let recorder = EcgRequestRecorder()
        let reply = EcgSyncTestSupport.okResponse("inserted", code: 201)
        MockURLProtocol.handler = { request in
            if request.targets("/api/insights/ecg") { recorder.record(request) }
            return reply(request)
        }
        let defaults = EcgSyncTestSupport.isolatedDefaults()
        let barrier = EcgVoltageBarrier()
        let source = FakeEcgSource(
            recordings: [EcgSyncTestSupport.recording()],
            volts: [EcgSyncTestSupport.defaultRecordingID: [0]],
            beforeVoltages: { await barrier.wait() }
        )
        let coordinator = EcgSyncTestSupport.makeCoordinator(
            api: api,
            keychain: keychain,
            source: source,
            defaultsProvider: defaults
        )
        let run = Task { await coordinator.sync() }
        await barrier.waitUntilEntered()

        try keychain.remove(forKey: KeychainKey.authToken)
        await barrier.release()
        let summary = await run.value

        #expect(recorder.isEmpty)
        #expect(summary.accepted == 0)
        #expect(summary.stoppedBecause == .transport)
        #expect(defaults().data(forKey: "hl.ecg.hk.anchor.user-A") == nil)
    }

    @Test("Tokenersatz am Draht bleibt auf A gepinnt und darf keinen Erfolg verbuchen")
    func tokenReplacementAtWireRetainsInitiatingBearerAndCursor() async throws {
        let (api, keychain) = EcgSyncTestSupport.makeClient(token: "bearer-A")
        try keychain.setString("user-A", forKey: KeychainKey.userID)
        let recorder = EcgRequestRecorder()
        let reply = EcgSyncTestSupport.okResponse("inserted", code: 201)
        MockURLProtocol.handler = { request in
            if request.targets("/api/insights/ecg") {
                recorder.record(request)
                try? keychain.setString("bearer-replacement", forKey: KeychainKey.authToken)
            }
            return reply(request)
        }
        let defaults = EcgSyncTestSupport.isolatedDefaults()
        let source = FakeEcgSource(
            recordings: [EcgSyncTestSupport.recording()],
            volts: [EcgSyncTestSupport.defaultRecordingID: [0]]
        )

        let summary = await EcgSyncTestSupport.makeCoordinator(
            api: api,
            keychain: keychain,
            source: source,
            defaultsProvider: defaults
        ).sync()

        #expect(recorder.count == 1)
        #expect(recorder.lastAuthorization == "Bearer bearer-A")
        #expect(summary.accepted == 0)
        #expect(summary.stoppedBecause == .transport)
        #expect(defaults().data(forKey: "hl.ecg.hk.anchor.user-A") == nil)
    }

    // MARK: - Too long: skipped, never truncated

    @Test("Eine zu lange Aufzeichnung wird übersprungen — und ihre Kurve gar nicht erst gelesen")
    func overlongRecordingIsSkippedNotTruncated() async {
        let (api, kc) = EcgSyncTestSupport.makeClient()
        let recorder = EcgRequestRecorder()
        MockURLProtocol.handler = { req in
            if req.targets("/api/insights/ecg") { recorder.record(req) }
            return (HTTPURLResponse(url: req.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!, Data())
        }
        let tooLong = EcgSyncTestSupport.recording(id: "long-1", samples: EcgIngestRequestDTO.maxSamples + 1)
        let defaults = EcgSyncTestSupport.isolatedDefaults()
        let source = FakeEcgSource(recordings: [tooLong], volts: ["long-1": [0.001]])
        let summary = await EcgSyncTestSupport.makeCoordinator(
            api: api,
            keychain: kc,
            source: source,
            defaultsProvider: defaults
        ).sync()

        #expect(summary.skipped[.tooManySamples] == 1)
        #expect(summary.accepted == 0)
        #expect(recorder.isEmpty, "abschneiden wäre eine Fälschung — es wird gar nichts gesendet")
        #expect(source.voltageRequests.isEmpty, "die Grenze wird an den Metadaten erkannt, vor dem Lesen")
        #expect(defaults().data(forKey: EcgSyncTestSupport.anchorKey) == nil)
    }

    @Test("Genau an der Grenze wird noch gesendet")
    func exactlyAtTheLimitStillUploads() async {
        let (api, kc) = EcgSyncTestSupport.makeClient()
        let reply = EcgSyncTestSupport.okResponse("inserted", code: 201)
        MockURLProtocol.handler = { reply($0) }
        let atLimit = EcgSyncTestSupport.recording(id: "edge-1", samples: EcgIngestRequestDTO.maxSamples)
        let source = FakeEcgSource(
            recordings: [atLimit],
            volts: ["edge-1": Array(repeating: 0.0001, count: EcgIngestRequestDTO.maxSamples)]
        )
        let summary = await EcgSyncTestSupport.makeCoordinator(api: api, keychain: kc, source: source).sync()
        #expect(summary.inserted == 1)
    }

    @Test("Ein fehlgeschlagener Cursor-Write hält den alten Anker")
    func persistenceFailureRetainsTheAnchor() async {
        let (api, kc) = EcgSyncTestSupport.makeClient()
        let reply = EcgSyncTestSupport.okResponse("inserted", code: 201)
        MockURLProtocol.handler = { reply($0) }
        let defaults = EcgSyncTestSupport.isolatedDefaults()
        let oldAnchor = Data("old-anchor".utf8)
        defaults().set(oldAnchor, forKey: EcgSyncTestSupport.anchorKey)
        let source = FakeEcgSource(
            recordings: [EcgSyncTestSupport.recording()],
            volts: ["11111111-2222-3333-4444-555555555555": [0]],
            nextAnchor: Data("new-anchor".utf8)
        )
        let coordinator = EcgSyncTestSupport.makeCoordinator(
            api: api,
            keychain: kc,
            source: source,
            defaultsProvider: defaults,
            anchorPersistenceOverride: { _, _ in false }
        )

        let summary = await coordinator.sync()

        #expect(summary.inserted == 1)
        #expect(summary.stoppedBecause == .persistence)
        #expect(defaults().data(forKey: EcgSyncTestSupport.anchorKey) == oldAnchor)
    }

    @Test("Cancellation ist kein Erfolg und hält den Cursor")
    func cancellationIsRetryable() async {
        #expect(
            EcgSyncCoordinator.disposition(for: HLError.canceled)
                == .halted(.transport)
        )
        let (api, keychain) = EcgSyncTestSupport.makeClient()
        let recorder = EcgRequestRecorder()
        let reply = EcgSyncTestSupport.okResponse("inserted", code: 201)
        MockURLProtocol.handler = { request in
            recorder.record(request)
            return reply(request)
        }
        let defaults = EcgSyncTestSupport.isolatedDefaults()
        let source = FakeEcgSource(
            recordings: [EcgSyncTestSupport.recording()],
            volts: [EcgSyncTestSupport.defaultRecordingID: [0]]
        )
        let coordinator = EcgSyncTestSupport.makeCoordinator(
            api: api,
            keychain: keychain,
            source: source,
            defaultsProvider: defaults
        )
        let run = Task {
            try? await Task.sleep(for: .seconds(60))
            return await coordinator.sync()
        }

        run.cancel()
        let summary = await run.value

        #expect(summary.stoppedBecause == .transport)
        #expect(defaults().data(forKey: EcgSyncTestSupport.anchorKey) == nil)
        #expect(recorder.isEmpty)
    }
}
