import Foundation

// swiftlint:disable force_unwrapping
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// **CU-37 — `result.ecg` on the archive-import poll status (server v1.34.1).**
///
/// The `export.zip` archive import is currently the ONLY route by which an ECG
/// recording reaches HealthLog: there is no JSON ingest route, and the app ships
/// no HealthKit ECG reader (GH #74 — the archive importer derives
/// `externalRecordingId` as a content hash over the full sample array while a
/// live sync would send `HKSample.uuid`, so shipping one before that is settled
/// would duplicate the same physical recording). Since v1.34.1 the poll status
/// therefore reports what happened to the ECG files it found, and the import
/// screen shows it — otherwise an upload gives no answer to "were my ECGs in
/// there?".
///
/// Drives the **real** ``APIClient`` over ``MockURLProtocol`` (never a mock
/// server — PROJECT_GUIDE.md), so a server-side shape change fails here as a decode
/// error rather than as a silently blank block on the screen. `.serialized`
/// because the suite owns the global stub handler.
@Suite("CU-37 — Apple-Health-Import: result.ecg", .serialized)
struct AppleHealthImportEcgResultTests {
    private func makeClient() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            cfAccessClientID: nil,
            cfAccessClientToken: nil,
            bundleID: "dev.healthlog.app",
            appVersion: "0.1.0",
            buildNumber: "1"
        )
        return APIClient(
            environment: env,
            keychain: InMemoryKeychain(),
            sessionConfiguration: .mock()
        )
    }

    private func respond(_ json: String) {
        MockURLProtocol.handler = { req in
            (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(json.utf8)
            )
        }
    }

    // MARK: - Wire decode

    @Test("terminaler Status trägt den vollständigen ecg-Block")
    func terminalStatusCarriesEcgCounters() async throws {
        // Verbatim shape from the v1.34.1 status route: five non-negative ints
        // next to `totals`/`perType`.
        respond(#"""
        {"data":{"jobId":"ij-9","status":"done","startedAt":"2026-07-30T10:00:00.000Z",
        "completedAt":"2026-07-30T10:04:00.000Z","uploadBytes":91234,
        "exportedAt":"2026-07-30T09:55:00.000Z",
        "progress":{"currentPhase":"done","recordsRead":42000,"rowsUpserted":41000,"percent":100},
        "result":{"totals":{"recordsRead":42000,"rowsUpserted":41000,"durationMs":240000},
        "perType":{"HEART_RATE":{"read":900,"inserted":880,"updated":20}},
        "ecg":{"discovered":7,"imported":5,"updated":1,"skipped":1,"failed":0}},
        "failureReason":null}}
        """#)

        let service = AppleHealthImportService(api: makeClient())
        let status = try await service.poll(jobId: "ij-9") { _ in }

        let ecg = try #require(status.result?.ecg, "der ecg-Block muss decodieren")
        #expect(ecg.discovered == 7)
        #expect(ecg.imported == 5)
        #expect(ecg.updated == 1)
        #expect(ecg.skipped == 1)
        #expect(ecg.failed == 0)
        // The block sits NEXT to the existing counters — it must not displace them.
        #expect(status.result?.totals?.rowsUpserted == 41000)
        #expect(status.result?.perType?["HEART_RATE"]?.inserted == 880)
    }

    @Test("Archiv ohne EKGs: discovered 0 ist eine Aussage, kein Fehler")
    func emptyDiscoveryIsNotAFailure() async throws {
        respond(#"""
        {"data":{"jobId":"ij-10","status":"done","startedAt":"2026-07-30T10:00:00.000Z",
        "completedAt":"2026-07-30T10:01:00.000Z","uploadBytes":512,
        "result":{"totals":{"recordsRead":10,"rowsUpserted":10},
        "ecg":{"discovered":0,"imported":0,"updated":0,"skipped":0,"failed":0}}}}
        """#)

        let service = AppleHealthImportService(api: makeClient())
        let status = try await service.poll(jobId: "ij-10") { _ in }

        #expect(status.status == .done, "ein EKG-freies Archiv ist ein normaler Erfolg")
        #expect(status.failureReason == nil)
        let ecg = try #require(status.result?.ecg)
        #expect(ecg.discovered == 0)
    }

    @Test("Server vor v1.34.1 (kein ecg-Block) decodiert weiter — der Block ist dann nil")
    func preV1341ServerStillDecodes() async throws {
        respond(#"""
        {"data":{"jobId":"ij-11","status":"done","startedAt":"2026-07-30T10:00:00.000Z",
        "completedAt":"2026-07-30T10:02:00.000Z","uploadBytes":4096,
        "result":{"totals":{"recordsRead":99,"rowsUpserted":99}}}}
        """#)

        let service = AppleHealthImportService(api: makeClient())
        let status = try await service.poll(jobId: "ij-11") { _ in }

        #expect(status.result?.ecg == nil, "ein fehlender Block darf den Poll nicht kippen")
        #expect(status.result?.totals?.recordsRead == 99)
    }

    @Test("Teil-Block eines künftigen Servers kippt den Poll nicht")
    func partialEcgBlockDecodes() async throws {
        respond(#"""
        {"data":{"jobId":"ij-12","status":"done","startedAt":"2026-07-30T10:00:00.000Z",
        "completedAt":"2026-07-30T10:02:00.000Z","uploadBytes":4096,
        "result":{"ecg":{"discovered":3,"imported":3}}}}
        """#)

        let service = AppleHealthImportService(api: makeClient())
        let status = try await service.poll(jobId: "ij-12") { _ in }

        let ecg = try #require(status.result?.ecg)
        #expect(ecg.discovered == 3)
        #expect(ecg.imported == 3)
        #expect(ecg.updated == nil)
        #expect(ecg.failed == nil)
    }
}
