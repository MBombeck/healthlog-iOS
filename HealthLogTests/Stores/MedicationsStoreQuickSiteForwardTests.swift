import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// **Bug #60 — quick-path injection-site forwarding.**
///
/// The quick "Genommen" surfaces (med card CTA, list ✓/swipe, Dashboard
/// upcoming-intakes sheet) must thread a captured `InjectionSite` through the
/// undoable mark into the request body — previously the site was dropped on
/// every quick path. These lock:
///
/// 1. `markIntakeQuickUndoable` / `markIntakeQuickReturningUndo` forward the
///    `injectionSite` into the real-intake POST body (real APIClient over
///    `MockURLProtocol`, per PROJECT_GUIDE.md: no mock server on the outbox path).
/// 2. The capture gate (`Medication.injectionSiteCaptureEnabled`) is unchanged:
///    an injection-tracked med is eligible (→ picker), an oral med is not
///    (→ immediate record, no popup). This is the predicate every quick path
///    consults before presenting the site sheet, so Lisinopril stays popup-free.
@Suite("MedicationsStore — quick-path injection-site forwarding (#60)", .serialized)
struct MedicationsStoreQuickSiteForwardTests {
    private static let scheduled = Date(timeIntervalSince1970: 1_714_550_400)
    private static let now = scheduled.addingTimeInterval(3600)

    private func pending(id: String = "intake-1", medId: String = "med-1") -> MedicationIntake {
        MedicationIntake(
            id: id,
            medicationId: medId,
            scheduledAt: Self.scheduled,
            takenAt: nil,
            status: .pending
        )
    }

    private func makeAPI() -> APIClient {
        let keychain = InMemoryKeychain()
        try? keychain.setString("token", forKey: KeychainKey.authToken)
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.5.0",
            buildNumber: "1"
        )
        return APIClient(
            environment: env,
            keychain: keychain,
            sessionConfiguration: .mock()
        )
    }

    private static func ok(_ request: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
    }

    private static let takenResponseBody = """
    {"data":{"id":"intake-1","medicationId":"med-1",\
    "scheduledFor":"2026-05-01T08:00:00Z","takenAt":"2026-05-01T09:00:00Z",\
    "skipped":false,"snoozedUntil":null}}
    """

    /// Reads either `httpBody` or the `httpBodyStream` URLSession converts a
    /// POST/PATCH body onto by the time `MockURLProtocol` sees the request.
    private static func bodyData(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }

    // MARK: - Store path forwards the injection site

    @Test("Undoable quick-mark forwards the chosen injection site into the POST body")
    @MainActor
    func undoableMarkForwardsInjectionSite() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        nonisolated(unsafe) var capturedBody: Data?
        MockURLProtocol.handler = { req in
            capturedBody = Self.bodyData(req)
            return (Self.ok(req), Data(Self.takenResponseBody.utf8))
        }
        let repo = MedicationsRepository(api: api, outbox: outbox)
        let store = MedicationsStore(repo: repo)
        store._testForceSet(todayIntakes: [pending()])

        let outcome = await store.markIntakeQuickUndoable(
            intakeId: "intake-1",
            status: .taken,
            now: Self.now,
            injectionSite: .thighLeft
        )
        #expect(outcome == .success)

        let bodyData = try #require(capturedBody, "The mark must have sent a request body")
        let bodyString = try #require(String(bytes: bodyData, encoding: .utf8))
        #expect(
            bodyString.contains(InjectionSite.thighLeft.serverRawValue),
            "POST body must carry the forwarded injection-site token (THIGH_LEFT), got: \(bodyString)"
        )
    }

    @Test("Returning-undo variant also forwards the injection site")
    @MainActor
    func returningUndoForwardsInjectionSite() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        nonisolated(unsafe) var capturedBody: Data?
        MockURLProtocol.handler = { req in
            capturedBody = Self.bodyData(req)
            return (Self.ok(req), Data(Self.takenResponseBody.utf8))
        }
        let repo = MedicationsRepository(api: api, outbox: outbox)
        let store = MedicationsStore(repo: repo)
        store._testForceSet(todayIntakes: [pending()])

        let (outcome, undo) = await store.markIntakeQuickReturningUndo(
            intakeId: "intake-1",
            status: .taken,
            now: Self.now,
            injectionSite: .abdomenLeftLower
        )
        #expect(outcome == .success)
        #expect(undo != nil, "A landed mark still yields an undo token")

        let bodyData = try #require(capturedBody)
        let bodyString = try #require(String(bytes: bodyData, encoding: .utf8))
        #expect(
            bodyString.contains(InjectionSite.abdomenLeftLower.serverRawValue),
            "POST body must carry ABDOMEN_LEFT, got: \(bodyString)"
        )
    }

    // MARK: - Capture-gate eligibility (drives whether a picker is presented)

    @Test("Injection-tracked med is capture-eligible → quick path presents the picker")
    func injectionMedIsEligible() {
        let med = Medication(
            id: "med-inj",
            name: "Insulin",
            dose: "10 IU",
            schedule: MedicationSchedule(times: []),
            deliveryForm: "INJECTION",
            trackInjectionSites: true
        )
        #expect(med.injectionSiteCaptureEnabled, "Injection + tracking on must be capture-eligible")
    }

    @Test("Oral non-GLP-1 med is NOT capture-eligible → quick path records immediately, no popup")
    func oralMedIsNotEligible() {
        let med = Medication(
            id: "med-oral",
            name: "Lisinopril",
            dose: "5 mg",
            treatmentClass: "OTHER",
            schedule: MedicationSchedule(times: []),
            deliveryForm: "ORAL",
            trackInjectionSites: false
        )
        #expect(
            !med.injectionSiteCaptureEnabled,
            "Oral non-GLP-1 med must NOT be capture-eligible (no popup — web parity)"
        )
    }
}

// swiftlint:enable force_unwrapping
