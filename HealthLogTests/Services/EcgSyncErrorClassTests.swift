import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// **GH #74 — die vier Fehlerklassen und die Ankerdisziplin.**
///
/// Zweite Hälfte von ``EcgSyncCoordinatorTests`` (file_length-Disziplin,
/// `PROJECT_GUIDE.md`). Hier steht die Unterscheidung, die die Einheit trägt:
/// `inserted` / `updated` / `duplicate` sind Erfolg; jeder andere Ausgang hält
/// den Anker. Der Anker IST die Warteschlange, damit keine Kurve in einem
/// Speicher landet, der sie überdauert.
///
/// `.serialized` — die Suite installiert den prozessweiten
/// `MockURLProtocol.handler`.
@Suite("EcgSyncCoordinator — Fehlerklassen + Anker", .serialized)
struct EcgSyncErrorClassTests {
    // MARK: - Error classes

    @Test("422 (unbekanntes Feld) hält fail-closed den Anker — die nächste Aufzeichnung darf trotzdem laufen")
    func unprocessableRetainsCursorWithoutBlockingTheRest() async {
        let (api, kc) = EcgSyncTestSupport.makeClient()
        let counter = EventTimeline()
        MockURLProtocol.handler = { req in
            guard req.targets("/api/insights/ecg") else {
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
            }
            counter.append("post")
            if counter.events.count == 1 {
                let body = Data(#"{"data":null,"error":"Unrecognized key: sampleCount"}"#.utf8)
                return (
                    HTTPURLResponse(url: req.url!, statusCode: 422, httpVersion: nil, headerFields: nil)!,
                    body
                )
            }
            let ok = Data(#"{"data":{"id":"row-2","status":"inserted"},"error":null}"#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!, ok)
        }
        let defaults = EcgSyncTestSupport.isolatedDefaults()
        let source = FakeEcgSource(
            recordings: [EcgSyncTestSupport.recording(id: "bad-1"), EcgSyncTestSupport.recording(id: "good-2")],
            volts: ["bad-1": [0.001], "good-2": [0.002]]
        )
        let summary = await EcgSyncTestSupport.makeCoordinator(
            api: api,
            keychain: kc,
            source: source,
            defaultsProvider: defaults
        ).sync()

        #expect(summary.skipped[.rejectedByServer] == 1)
        #expect(summary.inserted == 1, "eine abgelehnte Aufzeichnung hält die nächste nicht auf")
        #expect(summary.stoppedBecause == nil)
        #expect(defaults().data(forKey: EcgSyncTestSupport.anchorKey) == nil)
    }

    @Test("403 heisst aufhören, nicht wiederholen — der Anker wird gehalten")
    func moduleDisabledStopsAndHoldsTheAnchor() async {
        let (api, kc) = EcgSyncTestSupport.makeClient()
        MockURLProtocol.handler = { req in
            let body = Data(#"{"data":null,"error":"module disabled","meta":{"errorCode":"module.disabled","module":"insights"}}"#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!, body)
        }
        let defaults = EcgSyncTestSupport.isolatedDefaults()
        let source = FakeEcgSource(
            recordings: [EcgSyncTestSupport.recording(id: "a-1"), EcgSyncTestSupport.recording(id: "b-2")],
            volts: ["a-1": [0.001], "b-2": [0.002]]
        )
        let summary = await EcgSyncTestSupport.makeCoordinator(
            api: api,
            keychain: kc,
            source: source,
            defaultsProvider: defaults
        ).sync()

        #expect(summary.stoppedBecause == .gated)
        #expect(summary.accepted == 0)
        #expect(source.voltageRequests == ["a-1"], "nach dem Gatter wird die zweite Kurve gar nicht mehr gelesen")
        #expect(defaults().data(forKey: EcgSyncTestSupport.anchorKey) == nil, "Anker gehalten — nichts geht verloren")
    }

    @Test("429 heisst warten, nicht überspringen")
    func rateLimitHoldsTheAnchor() async {
        let (api, kc) = EcgSyncTestSupport.makeClient()
        MockURLProtocol.handler = { req in
            (
                HTTPURLResponse(
                    url: req.url!,
                    statusCode: 429,
                    httpVersion: nil,
                    headerFields: ["Retry-After": "0"]
                )!,
                Data(#"{"data":null,"error":"rate limited"}"#.utf8)
            )
        }
        let defaults = EcgSyncTestSupport.isolatedDefaults()
        let source = FakeEcgSource(recordings: [EcgSyncTestSupport.recording(id: "a-1")], volts: ["a-1": [0.001]])
        let summary = await EcgSyncTestSupport.makeCoordinator(
            api: api,
            keychain: kc,
            source: source,
            defaultsProvider: defaults
        ).sync()
        #expect(summary.stoppedBecause == .rateLimited)
        #expect(summary.skippedCount == 0)
        #expect(defaults().data(forKey: EcgSyncTestSupport.anchorKey) == nil)
    }

    @Test("Die vier Fehlerklassen gehen sauber auseinander")
    func dispositionTable() {
        typealias Outcome = EcgSyncCoordinator.RecordingOutcome
        // Halt + hold: a gate, an expired session, a spent budget, a broken pipe.
        #expect(EcgSyncCoordinator.disposition(for: HLError.moduleDisabled("insights")) == Outcome.halted(.gated))
        #expect(EcgSyncCoordinator.disposition(for: HLError.server(status: 403, code: nil, message: "")) == Outcome.halted(.gated))
        #expect(EcgSyncCoordinator.disposition(for: HLError.unauthorized) == Outcome.halted(.unauthorized))
        #expect(EcgSyncCoordinator.disposition(for: HLError.rateLimited(retryAfter: 5)) == Outcome.halted(.rateLimited))
        #expect(EcgSyncCoordinator.disposition(for: HLError.offline) == Outcome.halted(.transport))
        #expect(EcgSyncCoordinator.disposition(for: HLError.network(.timeout)) == Outcome.halted(.transport))
        #expect(EcgSyncCoordinator.disposition(for: HLError.server(status: 500, code: nil, message: "")) == Outcome.halted(.transport))
        // Validation is classified for diagnostics, but the sweep still holds
        // its anchor because only a released success consumes a recording.
        #expect(
            EcgSyncCoordinator.disposition(for: HLError.server(status: 422, code: nil, message: ""))
                == Outcome.skipped(.rejectedByServer)
        )
        #expect(
            EcgSyncCoordinator.disposition(for: HLError.server(status: 400, code: nil, message: ""))
                == Outcome.skipped(.rejectedByServer)
        )
    }

    @Test("Ein Netzfehler hält den Anker und wird nicht in die Outbox kopiert")
    func transportFailureHoldsAnchor() async {
        let (api, kc) = EcgSyncTestSupport.makeClient()
        MockURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        let defaults = EcgSyncTestSupport.isolatedDefaults()
        let source = FakeEcgSource(recordings: [EcgSyncTestSupport.recording(id: "a-1")], volts: ["a-1": [0.001]])
        let summary = await EcgSyncTestSupport.makeCoordinator(
            api: api,
            keychain: kc,
            source: source,
            defaultsProvider: defaults
        ).sync()
        #expect(summary.stoppedBecause == .transport)
        // The retry queue for this path IS the HealthKit store: the cursor stays
        // put, so the next wake re-reads exactly what did not land. Nothing of
        // the waveform is copied into a store that outlives the request.
        #expect(defaults().data(forKey: EcgSyncTestSupport.anchorKey) == nil)
    }

    @Test("Ein geleaster ECG-Request versucht einen 5xx genau einmal")
    func accountLeasedUploadDisablesTransportRetries() async {
        let (api, keychain) = EcgSyncTestSupport.makeClient()
        let recorder = EcgRequestRecorder()
        MockURLProtocol.handler = { request in
            recorder.record(request)
            return (
                HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
                Data(#"{"data":null,"error":"temporary"}"#.utf8)
            )
        }
        let source = FakeEcgSource(
            recordings: [EcgSyncTestSupport.recording()],
            volts: [EcgSyncTestSupport.defaultRecordingID: [0]]
        )

        let summary = await EcgSyncTestSupport.makeCoordinator(
            api: api,
            keychain: keychain,
            source: source
        ).sync()

        #expect(recorder.count == 1)
        #expect(summary.stoppedBecause == .transport)
    }

    @Test("Ein geleaster ECG-401 darf den globalen Refresh nicht starten")
    func accountLeasedUploadDisablesAuthenticationRecovery() async {
        let refreshes = EventTimeline()
        let (api, keychain) = EcgSyncTestSupport.makeClient(
            refreshHandler: {
                refreshes.append("refresh")
                return .refreshed
            }
        )
        let recorder = EcgRequestRecorder()
        MockURLProtocol.handler = { request in
            recorder.record(request)
            return (
                HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!,
                Data(#"{"data":null,"error":"expired"}"#.utf8)
            )
        }
        let source = FakeEcgSource(
            recordings: [EcgSyncTestSupport.recording()],
            volts: [EcgSyncTestSupport.defaultRecordingID: [0]]
        )

        let summary = await EcgSyncTestSupport.makeCoordinator(
            api: api,
            keychain: keychain,
            source: source
        ).sync()

        #expect(recorder.count == 1)
        #expect(refreshes.events.isEmpty)
        #expect(summary.stoppedBecause == .unauthorized)
    }

    // MARK: - Waveform read failure

    @Test("Eine unlesbare Kurve überspringt genau diese Aufzeichnung")
    func waveformFailureSkipsOnlyThatRecording() async {
        let (api, kc) = EcgSyncTestSupport.makeClient()
        let reply = EcgSyncTestSupport.okResponse("inserted", code: 201)
        MockURLProtocol.handler = { reply($0) }
        let defaults = EcgSyncTestSupport.isolatedDefaults()
        let source = FakeEcgSource(
            recordings: [EcgSyncTestSupport.recording(id: "broken-1"), EcgSyncTestSupport.recording(id: "fine-2")],
            volts: ["fine-2": [0.001]],
            failVoltagesFor: ["broken-1"]
        )
        let summary = await EcgSyncTestSupport.makeCoordinator(
            api: api,
            keychain: kc,
            source: source,
            defaultsProvider: defaults
        ).sync()
        #expect(summary.skipped[.waveformUnavailable] == 1)
        #expect(summary.inserted == 1)
        #expect(defaults().data(forKey: EcgSyncTestSupport.anchorKey) == nil)
    }

    @Test("Ein nicht darstellbarer Messwert verwirft die ganze Aufzeichnung, nicht nur den Wert")
    func nonFiniteSampleDropsTheWholeRecording() async {
        let (api, kc) = EcgSyncTestSupport.makeClient()
        let recorder = EcgRequestRecorder()
        let reply = EcgSyncTestSupport.okResponse("inserted", code: 201)
        MockURLProtocol.handler = { req in
            if req.targets("/api/insights/ecg") { recorder.record(req) }
            return reply(req)
        }
        let defaults = EcgSyncTestSupport.isolatedDefaults()
        let source = FakeEcgSource(
            recordings: [EcgSyncTestSupport.recording(id: "nan-1")],
            volts: ["nan-1": [0.001, .nan, 0.002]]
        )
        let summary = await EcgSyncTestSupport.makeCoordinator(
            api: api,
            keychain: kc,
            source: source,
            defaultsProvider: defaults
        ).sync()
        #expect(summary.skipped[.unreadableSample] == 1)
        #expect(recorder.isEmpty, "eine Teilkurve ist eine andere Messung — sie wird nicht gesendet")
        #expect(defaults().data(forKey: EcgSyncTestSupport.anchorKey) == nil)
    }

    // MARK: - Anchor discipline

    @Test("Der Anker wird nach einem erfolgreichen Durchlauf gesetzt und beim nächsten Mal mitgegeben")
    func anchorAdvancesAndIsReplayed() async {
        let (api, kc) = EcgSyncTestSupport.makeClient()
        let reply = EcgSyncTestSupport.okResponse("inserted", code: 201)
        MockURLProtocol.handler = { reply($0) }
        let defaults = EcgSyncTestSupport.isolatedDefaults()
        let source = FakeEcgSource(
            recordings: [EcgSyncTestSupport.recording(id: "a-1")],
            volts: ["a-1": [0.001]],
            nextAnchor: Data("cursor-1".utf8)
        )
        let coordinator = EcgSyncTestSupport.makeCoordinator(api: api, keychain: kc, source: source, defaultsProvider: defaults)
        _ = await coordinator.sync()
        #expect(defaults().data(forKey: EcgSyncTestSupport.anchorKey) == Data("cursor-1".utf8))

        source.setRecordings([])
        _ = await coordinator.sync()
        #expect(source.lastAnchorSeen == Data("cursor-1".utf8), "der nächste Durchlauf setzt dort auf")
    }

    @Test("Der erste leere Durchlauf setzt den Anker NICHT — verweigerte Leserechte sehen aus wie ein leerer Speicher")
    func firstRunEmptySweepDoesNotBurnTheAnchor() async {
        let (api, kc) = EcgSyncTestSupport.makeClient()
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }
        let defaults = EcgSyncTestSupport.isolatedDefaults()
        // Run 1 — HealthKit answers empty. That is exactly what a DENIED read
        // looks like, so the cursor must not be parked at "now".
        let denied = FakeEcgSource(recordings: [], volts: [:], nextAnchor: Data("now".utf8))
        _ = await EcgSyncTestSupport.makeCoordinator(api: api, keychain: kc, source: denied, defaultsProvider: defaults).sync()
        #expect(defaults().data(forKey: EcgSyncTestSupport.anchorKey) == nil)

        // Run 2 — permission granted later: the full history must still arrive.
        let reply = EcgSyncTestSupport.okResponse("inserted", code: 201)
        MockURLProtocol.handler = { reply($0) }
        let granted = FakeEcgSource(
            recordings: [EcgSyncTestSupport.recording(id: "old-1")],
            volts: ["old-1": [0.001]],
            nextAnchor: Data("cursor-1".utf8)
        )
        let summary = await EcgSyncTestSupport.makeCoordinator(api: api, keychain: kc, source: granted, defaultsProvider: defaults).sync()
        #expect(granted.lastAnchorSeen == nil, "immer noch von vorn")
        #expect(summary.inserted == 1)
    }

    @Test("Auch ein leerer Folgedurchlauf hält den Anker — nur Server-Erfolg rückt vor")
    func emptyIncrementalSweepRetainsCursor() {
        #expect(EcgSyncCoordinator.shouldSkipAnchorSave(hadPersistedAnchor: false, fetchedCount: 0))
        #expect(EcgSyncCoordinator.shouldSkipAnchorSave(hadPersistedAnchor: true, fetchedCount: 0))
        #expect(!EcgSyncCoordinator.shouldSkipAnchorSave(hadPersistedAnchor: false, fetchedCount: 1))
    }

    @Test("resetAnchor räumt den Cursor weg (Abmeldung / Opt-out)")
    func resetAnchorClearsTheCursor() async {
        let (api, kc) = EcgSyncTestSupport.makeClient()
        let reply = EcgSyncTestSupport.okResponse("inserted", code: 201)
        MockURLProtocol.handler = { reply($0) }
        let defaults = EcgSyncTestSupport.isolatedDefaults()
        let source = FakeEcgSource(
            recordings: [EcgSyncTestSupport.recording(id: "a-1")],
            volts: ["a-1": [0.001]],
            nextAnchor: Data("cursor-1".utf8)
        )
        let coordinator = EcgSyncTestSupport.makeCoordinator(api: api, keychain: kc, source: source, defaultsProvider: defaults)
        _ = await coordinator.sync()
        #expect(defaults().data(forKey: EcgSyncTestSupport.anchorKey) != nil)
        await coordinator.resetAnchor()
        #expect(defaults().data(forKey: EcgSyncTestSupport.anchorKey) == nil)
    }
}
