import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// **v1.39.1 (#1033) — the editor, the writes and the adherence read.**
///
/// The server keeps a record's stored schedule unless a write names
/// `trackIntake` (`e5236d2e6`, "keep a record-only schedule unless the write
/// names trackIntake"), and leaves `trackIntake` alone when a write omits it.
/// The app must therefore (a) open a record on its STORED schedule rather than
/// a daily-08:00 default, (b) never send `trackIntake` unless the person
/// changed it — or edited a record's schedule, where naming it is what makes
/// the edit apply — and (c) read `notApplicableReason: INTAKE_NOT_TRACKED`
/// (v1.39.1 compliance reads) tolerantly and render it neutrally.
@Suite("v1.39.1 #1033 — editor, writes and adherence of a record", .serialized, .mockURLSession)
struct MedicationTrackIntakeEditorV1391Tests {
    // MARK: - Editor prefill

    @Test("the editor opens a record on its stored 21:00 schedule, not a daily-08:00 default")
    func editorOpensOnRecordedSchedule() throws {
        let state = try EditMedicationFormState(from: MedicationTrackIntakeV1391Tests.recordOnly())
        #expect(state.times == [TimeOfDay(hour: 21, minute: 0)])
        #expect(state.trackIntake == false)
        #expect(state.serverTrackIntake == false)
    }

    @Test("an older server leaves the switch unknown, so it is neither offered nor sent")
    func olderServerSwitchUnknown() throws {
        let med = try MedicationTrackIntakeV1391Tests.decode(MedicationTrackIntakeV1391Tests.medicationJSON(
            trackIntake: nil, schedules: [MedicationTrackIntakeV1391Tests.schedule("08:00")]
        ))
        let state = EditMedicationFormState(from: med)
        #expect(state.serverTrackIntake == nil)
        #expect(state.trackIntake)
        #expect(MedicationTrackIntakeWrite.value(server: nil, edited: false, scheduleChanged: true) == nil)
    }

    // MARK: - What the PUT names

    @Test("trackIntake is named only when flipped, or to make a record's schedule edit apply")
    func writeDecision() {
        // Untouched switch, no schedule edit: never sent (tracked or record).
        #expect(MedicationTrackIntakeWrite.value(server: true, edited: true, scheduleChanged: false) == nil)
        #expect(MedicationTrackIntakeWrite.value(server: false, edited: false, scheduleChanged: false) == nil)
        // A tracked medication's schedule edit needs no flag.
        #expect(MedicationTrackIntakeWrite.value(server: true, edited: true, scheduleChanged: true) == nil)
        // Flipped either way: sent as chosen.
        #expect(MedicationTrackIntakeWrite.value(server: true, edited: false, scheduleChanged: false) == false)
        #expect(MedicationTrackIntakeWrite.value(server: false, edited: true, scheduleChanged: false) == true)
        // A record's schedule edit echoes `false`, or the server drops it.
        #expect(MedicationTrackIntakeWrite.value(server: false, edited: false, scheduleChanged: true) == false)
    }

    @Test("a rename of a record over the real repository sends neither trackIntake nor schedules")
    @MainActor
    func renameOfRecordOmitsFlag() async throws {
        nonisolated(unsafe) var captured: [String: Any]?
        let record = MedicationTrackIntakeV1391Tests.medicationJSON(
            trackIntake: false, schedules: [], recorded: [MedicationTrackIntakeV1391Tests.schedule("21:00")]
        )
        let responseBody = #"{"data":"# + record + "}"
        MockURLProtocol.install { req in
            captured = Self.bodyData(req).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            return (Self.ok(req), Data(responseBody.utf8))
        }
        let repo = try MedicationsRepository(api: Self.makeAPI(), outbox: OutboxQueue(inMemory: true))
        let form = MedicationTrackIntakeFormValue(tracked: false, server: false)
        let patch = MedicationsRepository.MedicationPatch(
            name: "Atorvastatin 20",
            trackIntake: MedicationTrackIntakeWrite.value(form, scheduleChanged: false)
        )
        let updated = try await repo.update(id: "med-rec", patch: patch)

        let body = try #require(captured)
        #expect(body["name"] as? String == "Atorvastatin 20")
        #expect(body["trackIntake"] == nil)
        #expect(body["schedules"] == nil)
        #expect(!updated.tracksIntake)
        #expect(updated.displaySchedule.times == [TimeOfDay(hour: 21, minute: 0)])
    }

    @Test("a flipped switch is encoded; an untouched one is absent from the wire")
    func patchEncoding() throws {
        let flipped = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(MedicationsRepository.MedicationPatch(trackIntake: true))
        ) as? [String: Any]
        #expect(flipped?["trackIntake"] as? Bool == true)
        let untouched = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(MedicationsRepository.MedicationPatch(name: "X"))
        ) as? [String: Any]
        #expect(untouched?.keys.contains("trackIntake") == false)
    }

    // MARK: - Adherence: INTAKE_NOT_TRACKED

    static let notTrackedPayload = #"""
    {"applicable":false,"notApplicableReason":"INTAKE_NOT_TRACKED",
     "compliance7":{"totalExpected":0,"taken":0,"skipped":0,"missed":0,"rate":0,"streak":0},
     "compliance30":{"totalExpected":0,"taken":0,"skipped":0,"missed":0,"rate":0,"streak":0},
     "dailyCompliance":{},"complianceDisplay":null}
    """#

    @Test("INTAKE_NOT_TRACKED decodes on the per-medication and the batched read")
    func decodesReason() throws {
        let payload = try JSONDecoder.hlDefault.decode(
            MedicationCompliancePayload.self, from: Data(Self.notTrackedPayload.utf8)
        )
        #expect(!payload.isApplicable)
        #expect(payload.notApplicableReason == .intakeNotTracked)
        let entry = try JSONDecoder.hlDefault.decode(MedicationComplianceSummaryEntry.self, from: Data(#"""
        {"medicationId":"med-rec","applicable":false,"notApplicableReason":"INTAKE_NOT_TRACKED",
         "compliance7":{"totalExpected":0,"taken":0,"skipped":0,"missed":0,"rate":0,"streak":0},
         "compliance30":{"totalExpected":0,"taken":0,"skipped":0,"missed":0,"rate":0,"streak":0},
         "complianceDisplay":null}
        """#.utf8))
        #expect(entry.notApplicableReason == .intakeNotTracked)
    }

    @Test("a reason this build does not know keeps the payload and reads neutral; v1.39.0 shape unchanged")
    func unknownAndOlderReasons() throws {
        let novel = Self.notTrackedPayload.replacingOccurrences(of: "INTAKE_NOT_TRACKED", with: "zz_from_the_future")
        let payload = try JSONDecoder.hlDefault.decode(MedicationCompliancePayload.self, from: Data(novel.utf8))
        #expect(payload.notApplicableReason == .unknown)
        #expect(!payload.isApplicable)
        let older = Self.notTrackedPayload.replacingOccurrences(of: "INTAKE_NOT_TRACKED", with: "NO_LOCAL_SCHEDULE")
        let v139 = try JSONDecoder.hlDefault.decode(MedicationCompliancePayload.self, from: Data(older.utf8))
        #expect(v139.notApplicableReason == .noLocalSchedule)
    }

    @Test("the detail KPI says 'not tracked' for a record, never its zero placeholder")
    @MainActor
    func kpiNotTracked() throws {
        let repo = try MedicationsRepository(api: Self.makeAPI(), outbox: OutboxQueue(inMemory: true))
        let payload = try JSONDecoder.hlDefault.decode(
            MedicationCompliancePayload.self, from: Data(Self.notTrackedPayload.utf8)
        )
        // The server's answer alone, on a medication the list still shows tracked.
        let stale = try MedicationDetailStore(medication: MedicationTrackIntakeV1391Tests.tracked(), repo: repo)
        stale._testInject(intakes: [], compliance: payload)
        #expect(stale.complianceKPIState() == .notTracked)
        // The record itself, before any payload landed.
        let record = try MedicationDetailStore(medication: MedicationTrackIntakeV1391Tests.recordOnly(), repo: repo)
        record._testInject(intakes: [], settled: false)
        #expect(record.complianceKPIState() == .notTracked)
    }

    // MARK: - Helpers

    private static func makeAPI() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            cfAccessClientID: nil,
            cfAccessClientToken: nil,
            bundleID: "dev.healthlog.app",
            appVersion: "1.1.0",
            buildNumber: "1"
        )
        let keychain = InMemoryKeychain()
        try? keychain.setString("token", forKey: KeychainKey.authToken)
        return APIClient(environment: env, keychain: keychain, sessionConfiguration: .mock())
    }

    private static func ok(_ req: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(
            url: req.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
    }

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
}
