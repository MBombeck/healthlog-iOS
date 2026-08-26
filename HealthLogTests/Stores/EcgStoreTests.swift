import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// The ECG store's surface gate + the page's presentation rules, driven through
/// the REAL `APIClient` over `MockURLProtocol`.
///
/// The load-bearing assertions here are regulatory as much as functional:
/// - `hasRecordings` is the ONLY gate the ECG pill/page hangs on (mood
///   precedent) — no recordings means no surface at all
/// - a row without a waveform is NOT openable (no push into an empty screen)
/// - the clinician note fires only for a NON-NORMAL DEVICE verdict
/// - the disclaimer + result copy exist verbatim (copy contract with the web)
@Suite("EcgStore — surface gate + device-verdict framing", .serialized)
@MainActor
struct EcgStoreTests {
    private func makeStore() -> EcgStore {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.14.1",
            buildNumber: "1"
        )
        let api = APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
        return EcgStore(repo: EcgRepository(api: api))
    }

    private func respond(_ json: String, status: Int = 200) {
        let body = Data(json.utf8)
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, body)
        }
    }

    private let twoRecordings = #"""
    {"data":{"recordings":[
      {"id":"ecg-1","recordedAt":"2026-01-15T08:30:00.000Z","durationSeconds":30,
       "samplingFrequency":300,"sampleCount":9000,"averageHeartRate":62,"lead":"I",
       "classification":"NOT_DETECTED","source":"WITHINGS","hasWaveform":true},
      {"id":"ecg-2","recordedAt":"2025-12-24T07:00:00.000Z","durationSeconds":null,
       "samplingFrequency":null,"sampleCount":0,"averageHeartRate":null,"lead":null,
       "classification":"IRREGULAR","source":"WITHINGS","hasWaveform":false}
    ],"hasRecordings":true},"error":null}
    """#

    @Test("no recordings → the surface gate stays CLOSED (no pill, no page)")
    func emptyGateClosed() async {
        let store = makeStore()
        respond(#"{"data":{"recordings":[],"hasRecordings":false},"error":null}"#)
        await store.load()
        #expect(store.hasSettledOnce)
        #expect(!store.hasRecordings)
        #expect(store.recordings.isEmpty)
        #expect(store.latest == nil)
    }

    @Test("recordings present → the gate opens and the list keeps server order")
    func gateOpensWithRecordings() async {
        let store = makeStore()
        respond(twoRecordings)
        await store.load()
        #expect(store.hasRecordings)
        #expect(store.recordings.map(\.id) == ["ecg-1", "ecg-2"])
        #expect(store.latest?.id == "ecg-1")
    }

    @Test("403 (module or assistant surface off) → the gate stays closed, no error")
    func gatedOffStaysClosed() async {
        let store = makeStore()
        respond(#"{"data":null,"error":{"message":"Assistant surface disabled","code":"assistant.disabled.insightStatus"}}"#, status: 403)
        await store.load()
        #expect(store.list == nil)
        #expect(!store.hasRecordings)
        #expect(!store.loadFailed, "a gate is not a failure")
    }

    @Test("a recording without a waveform is NOT openable (no dead push)")
    func waveformlessRowNotOpenable() async {
        let store = makeStore()
        respond(twoRecordings)
        await store.load()
        let withWaveform = store.recordings[0]
        let withoutWaveform = store.recordings[1]
        #expect(EcgPresentation.isOpenable(withWaveform))
        #expect(!EcgPresentation.isOpenable(withoutWaveform))
    }

    @Test("the clinician note follows the DEVICE verdict only")
    func clinicianNoteFollowsDeviceVerdict() async {
        let store = makeStore()
        respond(twoRecordings)
        await store.load()
        #expect(!EcgPresentation.showsClinicianNote(for: store.recordings[0].verdict))
        #expect(EcgPresentation.showsClinicianNote(for: store.recordings[1].verdict))
    }

    @Test("clearOnLogout wipes the list so the next user never sees it")
    func logoutWipes() async {
        let store = makeStore()
        respond(twoRecordings)
        await store.load()
        #expect(store.hasRecordings)
        store.clearOnLogout()
        #expect(store.list == nil)
        #expect(!store.hasRecordings)
        #expect(!store.hasSettledOnce)
    }

    @Test("a transport failure keeps the painted list and flags the calm note")
    func transportFailureKeepsList() async {
        let store = makeStore()
        respond(twoRecordings)
        await store.load()
        respond(#"{"data":null,"error":{"message":"Bad request"}}"#, status: 400)
        await store.refresh()
        #expect(store.hasRecordings, "a blip must not wipe a visible list")
        #expect(store.loadFailed)
    }

    // MARK: - Copy contract

    @Test("the device-result copy is present and attributed to the device")
    func resultCopyIsAttributed() {
        // The label is the DEVICE's result…
        let label = EcgPresentation.resultLabel(for: .notDetected)
        #expect([
            "No signs of atrial fibrillation",
            "Keine Anzeichen von Vorhofflimmern"
        ].contains(label))
        // …and it is never shown without naming the device as its author.
        let attribution = EcgPresentation.attribution(for: .notDetected)
        #expect(attribution.contains(label))
        #expect(
            attribution.contains("recording device") || attribution.contains("Aufzeichnungsgerät"),
            "the result must always be attributed to the recording device"
        )
    }

    @Test("an unknown device literal is shown VERBATIM, never reinterpreted")
    func unknownVerdictVerbatim() {
        #expect(EcgPresentation.resultLabel(for: .unknown("SINUS_RHYTHM")) == "SINUS_RHYTHM")
    }

    @Test("the permanent disclaimer copy exists and denies interpretation")
    func disclaimerCopyContract() {
        let disclaimer = String(localized: "insights.ecg.disclaimer")
        #expect(disclaimer != "insights.ecg.disclaimer", "the disclaimer must be localized")
        #expect(
            disclaimer.contains("does not read or interpret")
                || disclaimer.contains("liest oder interpretiert"),
            "the disclaimer must state that HealthLog does not interpret ECGs"
        )
        let note = String(localized: "insights.ecg.clinicianNote")
        #expect(note != "insights.ecg.clinicianNote")
    }

    @Test("metadata values render verbatim, with an honest dash for the unknown")
    func metadataValues() {
        #expect(EcgPresentation.durationValue(30).contains("30"))
        #expect(EcgPresentation.bpmValue(62).contains("62"))
        #expect(EcgPresentation.hzValue(300).contains("300"))
        let unknown = String(localized: "insights.ecg.meta.unknown")
        #expect(EcgPresentation.durationValue(nil) == unknown)
        #expect(EcgPresentation.bpmValue(nil) == unknown)
        #expect(EcgPresentation.hzValue(nil) == unknown)
        #expect(EcgPresentation.leadValue(nil) == unknown)
        #expect(EcgPresentation.leadValue("II") == "II", "an unexpected lead is shown verbatim")
    }
}

// swiftlint:enable force_unwrapping
