import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// P8 B-5 — the pulse page's ECG cross-link.
///
/// The row exists ONLY on the pulse page, only with a cloud surface, and only
/// when the operator actually has recordings — otherwise it would be a tap into
/// a page that has nothing to show (web un-mounts it for the same reason,
/// `ecg-cross-link.tsx:27-30`). It also must never say anything about the
/// trace: the caption carries the count plus the DEVICE's last result, nothing
/// derived.
@Suite("ECG cross-link — pulse-only, data-gated, device-attributed", .serialized)
@MainActor
struct EcgCrossLinkTests {
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

    private func respond(_ json: String) {
        let body = Data(json.utf8)
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
    }

    /// The row's gate, expressed exactly as `ecgCrossLinkRow` spells it.
    private func isVisible(kind: MetricKind, canShowCloudInsights: Bool, store: EcgStore) -> Bool {
        kind == .pulse && canShowCloudInsights && store.hasRecordings
    }

    @Test("visible on the pulse page when recordings exist")
    func visibleOnPulseWithRecordings() async {
        let store = makeStore()
        respond(#"""
        {"data":{"recordings":[
          {"id":"ecg-1","recordedAt":"2026-01-15T08:30:00.000Z","durationSeconds":30,
           "samplingFrequency":300,"sampleCount":9000,"averageHeartRate":62,"lead":"I",
           "classification":"NOT_DETECTED","source":"WITHINGS","hasWaveform":true}
        ],"hasRecordings":true},"error":null}
        """#)
        await store.load()
        #expect(isVisible(kind: .pulse, canShowCloudInsights: true, store: store))
    }

    @Test("un-mounts without recordings, off the pulse page, and without a cloud surface")
    func hiddenOtherwise() async {
        let empty = makeStore()
        respond(#"{"data":{"recordings":[],"hasRecordings":false},"error":null}"#)
        await empty.load()
        #expect(!isVisible(kind: .pulse, canShowCloudInsights: true, store: empty))

        let full = makeStore()
        respond(#"""
        {"data":{"recordings":[
          {"id":"ecg-1","recordedAt":"2026-01-15T08:30:00.000Z","durationSeconds":30,
           "samplingFrequency":300,"sampleCount":9000,"averageHeartRate":62,"lead":"I",
           "classification":"IRREGULAR","source":"WITHINGS","hasWaveform":true}
        ],"hasRecordings":true},"error":null}
        """#)
        await full.load()
        #expect(!isVisible(kind: .hrv, canShowCloudInsights: true, store: full), "pulse page only")
        #expect(!isVisible(kind: .pulse, canShowCloudInsights: false, store: full), "server-derived only")
    }

    @Test("the caption is the count plus the DEVICE's last result — nothing derived")
    func captionCopyContract() {
        let one = String(localized: "insights.ecg.crossLink.recordingsOne")
        #expect(one != "insights.ecg.crossLink.recordingsOne")
        let many = String(localized: "insights.ecg.crossLink.recordingsMany \(4)")
        #expect(many.contains("4"))
        let latest = String(localized: "insights.ecg.crossLink.latestResult \(EcgPresentation.resultLabel(for: .irregular))")
        #expect(
            latest.contains("device result") || latest.contains("Geräte-Ergebnis"),
            "the cross-link must attribute the result to the device"
        )
        let title = String(localized: "insights.ecg.crossLink.title")
        #expect(title != "insights.ecg.crossLink.title")
    }
}

// swiftlint:enable force_unwrapping
