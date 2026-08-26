import Foundation
import Testing
#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

// swiftlint:disable force_unwrapping

/// **CU-18 — Import-Job-Status (`GET /api/medications/{id}/intake/import/{jobId}/status`).**
///
/// Pinnt die in Server v1.33.0 komplett ersetzte `result`- / `progress`-Shape
/// (belegt in `.planning/parity/WIRE-SHAPES-v134.md` §1 gegen
/// `src/lib/jobs/medication-intake-import.ts` +
/// `src/lib/medications/intake-import-job-status.ts`).
///
/// Getrieben wird der **echte** ``APIClient`` über `MockURLProtocol` (PROJECT_GUIDE.md:
/// nie ein Mock-Server), damit Envelope, Date-Strategie und DTO gemeinsam
/// geprüft sind.
///
/// Die drei Fallen, die dieser Suite den Namen geben:
/// 1. `status == "done"` garantiert **nicht** `result != nil`.
/// 2. `reason` ist ein toleranter String, kein geschlossenes Enum.
/// 3. `progress` kann `{}` sein (Spalten-Default, ungeprüft durchgereicht).
@Suite("CU-18 — Medikamenten-Import-Job-Status", .serialized)
struct MedicationIntakeImportStatusWireTests {
    private func makeClient() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            cfAccessClientID: nil,
            cfAccessClientToken: nil,
            bundleID: "dev.healthlog.app",
            appVersion: "0.1.0",
            buildNumber: "1"
        )
        return APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
    }

    private func respond(_ json: String, status: Int = 200) {
        MockURLProtocol.handler = { req in
            (
                HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!,
                Data(json.utf8)
            )
        }
    }

    private func fetchStatus(_ json: String) async throws -> MedicationIntakeImportStatusDTO {
        respond(json)
        let req = APIRequest<MedicationIntakeImportStatusDTO>
            .get("/api/medications/med-1/intake/import/job-1/status")
        return try await makeClient().send(req)
    }

    // MARK: - Kickoff

    @Test("Kickoff-202 dekodiert jobId + relativen statusUrl")
    func kickoffDecodes() async throws {
        respond(#"""
        {"data":{"jobId":"cl-job-1","status":"queued",
        "statusUrl":"/api/medications/med-1/intake/import/cl-job-1/status"}}
        """#, status: 202)
        // Der echte Kickoff lädt eine Exportdatei hoch; hier zählt nur, dass die
        // 202-Antwort samt `statusUrl` durch den echten Client decodiert.
        let req = APIRequest<MedicationIntakeImportKickoffDTO>(
            method: .post,
            path: "/api/medications/med-1/intake/import"
        )
        let kickoff = try await makeClient().send(req)
        #expect(kickoff.jobId == "cl-job-1")
        #expect(kickoff.status == "queued")
        #expect(kickoff.statusUrl == "/api/medications/med-1/intake/import/cl-job-1/status")
    }

    // MARK: - Laufender Job

    @Test("Laufender Job: volle progress-Shape, result null, nicht terminal")
    func runningJobDecodesProgress() async throws {
        let status = try await fetchStatus(#"""
        {"data":{"jobId":"job-1","status":"running",
        "progress":{"processed":40,"total":100,"imported":31,
        "skippedByReason":{"already_recorded":6,"missing_timestamp":3},
        "skipDetails":[{"line":12,"reason":"missing_timestamp"},{"line":19,"reason":"already_recorded"}],
        "skippedDetailsOmitted":7,
        "touchedDays":["2026-07-01","2026-07-02"],"rollupProcessed":2},
        "result":null,"failureReason":null,
        "createdAt":"2026-07-30T08:00:00.000Z","startedAt":"2026-07-30T08:00:05.000Z","completedAt":null}}
        """#)

        #expect(status.phase == .running)
        #expect(!status.isTerminal)
        #expect(status.outcome == .running)
        #expect(status.result == nil)

        let progress = try #require(status.progress)
        #expect(progress.processed == 40)
        #expect(progress.total == 100)
        #expect(progress.imported == 31)
        #expect(progress.rollupProcessed == 2)
        #expect(progress.skippedByReason["already_recorded"] == 6)
        #expect(progress.skippedByReason["missing_timestamp"] == 3)
        // Ein Grund ohne Skips fehlt — er steht NICHT als 0 drin.
        #expect(progress.skippedByReason["status_unknown"] == nil)
        #expect(progress.skipDetails?.count == 2)
        #expect(progress.skipDetails?.first?.line == 12)
        #expect(progress.skippedDetailsOmitted == 7)
        #expect(progress.touchedDays == ["2026-07-01", "2026-07-02"])
        #expect(progress.fraction == 0.4)
        #expect(status.completedAt == nil)
        #expect(status.startedAt != nil)
    }

    @Test("progress == {} dekodiert zu Nullwerten und liefert KEINEN erfundenen Fortschritt")
    func emptyProgressObjectDecodes() async throws {
        let status = try await fetchStatus(#"""
        {"data":{"jobId":"job-legacy","status":"queued","progress":{},"result":null,
        "failureReason":null,"createdAt":"2026-07-30T08:00:00.000Z","startedAt":null,"completedAt":null}}
        """#)
        let progress = try #require(status.progress)
        #expect(progress.processed == 0)
        #expect(progress.total == 0)
        #expect(progress.skippedByReason.isEmpty)
        #expect(progress.skipDetails == nil, "abwesend ist nicht dasselbe wie []")
        #expect(progress.touchedDays.isEmpty)
        // Kein 0-%-Balken behaupten, solange `total` unbekannt ist.
        #expect(progress.fraction == nil)
        #expect(status.outcome == .running)
    }

    @Test("Nicht-objektiges progress-JSON kippt den Poll nicht")
    func nonObjectProgressTolerated() async throws {
        let status = try await fetchStatus(#"""
        {"data":{"jobId":"job-weird","status":"running","progress":"unerwartet",
        "result":null,"failureReason":null,"createdAt":"2026-07-30T08:00:00.000Z"}}
        """#)
        #expect(status.progress == nil)
        #expect(status.phase == .running)
        #expect(status.outcome == .running)
    }

    // MARK: - Fertiger Job mit Ergebnis

    @Test("done mit result: neue Shape imported/skipped/skipReasons/skipDetails")
    func doneWithResultDecodes() async throws {
        let status = try await fetchStatus(#"""
        {"data":{"jobId":"job-1","status":"done",
        "progress":{"processed":100,"total":100,"imported":88,
        "skippedByReason":{"already_recorded":9,"duplicate_in_file":3},
        "touchedDays":["2026-07-01"],"rollupProcessed":1},
        "result":{"imported":88,"skipped":12,
        "skipReasons":[{"reason":"already_recorded","count":9},{"reason":"duplicate_in_file","count":3}],
        "skipDetails":[{"line":4,"reason":"duplicate_in_file"}],"skippedDetailsOmitted":11},
        "failureReason":null,"createdAt":"2026-07-30T08:00:00.000Z",
        "startedAt":"2026-07-30T08:00:05.000Z","completedAt":"2026-07-30T08:04:00.000Z"}}
        """#)

        #expect(status.phase == .done)
        #expect(status.isTerminal)
        let result = try #require(status.result)
        #expect(result.imported == 88)
        #expect(result.skipped == 12)
        #expect(result.skipReasons.count == 2)
        // Absteigend nach Anzahl, wie der Server sortiert.
        #expect(result.skipReasons.first?.reason == "already_recorded")
        #expect(result.skipReasons.first?.count == 9)
        #expect(result.skipReasons.map(\.count).reduce(0, +) == result.skipped)
        #expect(result.skipDetails?.first?.line == 4)
        #expect(result.skippedDetailsOmitted == 11)
        #expect(!result.isClean)
        #expect(status.outcome == .finished(result))
        #expect(status.completedAt != nil)
    }

    @Test("Lauf ohne Skips: skipReasons ist ein leeres Array, nicht null")
    func cleanRunHasEmptySkipReasons() async throws {
        let status = try await fetchStatus(#"""
        {"data":{"jobId":"job-clean","status":"done","progress":{"processed":10,"total":10,"imported":10,
        "skippedByReason":{},"touchedDays":["2026-07-01"],"rollupProcessed":1},
        "result":{"imported":10,"skipped":0,"skipReasons":[]},
        "failureReason":null,"createdAt":"2026-07-30T08:00:00.000Z","completedAt":"2026-07-30T08:01:00.000Z"}}
        """#)
        let result = try #require(status.result)
        #expect(result.skipReasons.isEmpty)
        #expect(result.isClean)
        #expect(result.skipDetails == nil)
        #expect(status.outcome == .finished(result))
    }

    // MARK: - Die Falle: done OHNE result

    @Test("done ohne result ist ehrlich 'fertig ohne Details' — kein Fehler, kein Null-Ergebnis")
    func doneWithoutResultIsHonest() async throws {
        // Fall 3 der Allowlist-Projektion: `projectMedicationImportResult`
        // verwirft einen unstimmigen Blob still, `status` bleibt "done".
        let status = try await fetchStatus(#"""
        {"data":{"jobId":"job-projected-away","status":"done",
        "progress":{"processed":50,"total":50,"imported":50,"skippedByReason":{},
        "touchedDays":[],"rollupProcessed":0},
        "result":null,"failureReason":null,"createdAt":"2026-07-30T08:00:00.000Z",
        "startedAt":"2026-07-30T08:00:01.000Z","completedAt":"2026-07-30T08:03:00.000Z"}}
        """#)
        #expect(status.phase == .done)
        #expect(status.result == nil)
        // Terminal → nicht weiterpollen, aber KEIN Fehlerzustand.
        #expect(status.isTerminal)
        #expect(status.outcome == .finishedWithoutDetails)
        #expect(status.outcome != .failed)
    }

    // MARK: - Fehlschlag

    @Test("failed: outcome ist .failed; failureReason trägt keine Ursache")
    func failedJobDecodes() async throws {
        let status = try await fetchStatus(#"""
        {"data":{"jobId":"job-bad","status":"failed","progress":{"processed":3,"total":50,"imported":0,
        "skippedByReason":{},"touchedDays":[],"rollupProcessed":0},
        "result":null,"failureReason":"Medication intake import failed",
        "createdAt":"2026-07-30T08:00:00.000Z","startedAt":"2026-07-30T08:00:01.000Z",
        "completedAt":"2026-07-30T08:00:09.000Z"}}
        """#)
        #expect(status.phase == .failed)
        #expect(status.isTerminal)
        #expect(status.outcome == .failed)
        #expect(status.result == nil)
        // Der Sanitiser gibt immer denselben konstanten String zurück — er darf
        // nie als Ursachentext gerendert werden.
        #expect(status.failureReason == "Medication intake import failed")
    }

    // MARK: - Toleranzen

    @Test("Unbekanntes status-Literal gilt als 'läuft noch', nicht als Fehler")
    func unknownStatusIsNotTerminal() async throws {
        let status = try await fetchStatus(#"""
        {"data":{"jobId":"job-future","status":"paused","progress":{},"result":null,
        "failureReason":null,"createdAt":"2026-07-30T08:00:00.000Z"}}
        """#)
        #expect(status.statusRaw == "paused")
        #expect(status.phase == nil)
        #expect(!status.isTerminal)
        #expect(status.outcome == .running)
    }

    @Test("Alle 16 bekannten reason-Literale decodieren wortwörtlich")
    func allSixteenKnownReasonsDecode() async throws {
        let known = MedicationIntakeImportSkipReasons.known
        #expect(known.count == 16)
        let groups = known.map { #"{"reason":"\#($0)","count":1}"# }.joined(separator: ",")
        let status = try await fetchStatus(#"""
        {"data":{"jobId":"job-all","status":"done","progress":{},
        "result":{"imported":0,"skipped":16,"skipReasons":[\#(groups)]},
        "failureReason":null,"createdAt":"2026-07-30T08:00:00.000Z","completedAt":"2026-07-30T08:01:00.000Z"}}
        """#)
        let result = try #require(status.result)
        #expect(result.skipReasons.map(\.reason) == known)
        #expect(result.skipReasons.allSatisfy { $0.count == 1 })
        #expect(result.skipped == 16)
    }

    @Test("Ein siebzehntes, unbekanntes reason-Literal decodiert mit — die Liste ist kein Wächter")
    func unknownReasonLiteralSurvives() async throws {
        let status = try await fetchStatus(#"""
        {"data":{"jobId":"job-17","status":"done","progress":{},
        "result":{"imported":5,"skipped":4,
        "skipReasons":[{"reason":"quantum_uncertainty","count":3},{"reason":"already_recorded","count":1}],
        "skipDetails":[{"line":8,"reason":"quantum_uncertainty"}],"skippedDetailsOmitted":0},
        "failureReason":null,"createdAt":"2026-07-30T08:00:00.000Z","completedAt":"2026-07-30T08:01:00.000Z"}}
        """#)
        let result = try #require(status.result)
        #expect(result.skipReasons.count == 2)
        #expect(result.skipReasons.first?.reason == "quantum_uncertainty")
        #expect(!MedicationIntakeImportSkipReasons.known.contains("quantum_uncertainty"))
        #expect(result.skipDetails?.first?.reason == "quantum_uncertainty")
        // Die Summe bleibt konsistent — nichts wurde stillschweigend verworfen.
        #expect(result.skipReasons.map(\.count).reduce(0, +) == result.skipped)
    }

    @Test("Magere Alt-Antwort (nur jobId + status) decodiert")
    func minimalPayloadDecodes() async throws {
        let status = try await fetchStatus(#"{"data":{"jobId":"job-lean","status":"queued"}}"#)
        #expect(status.jobId == "job-lean")
        #expect(status.phase == .queued)
        #expect(status.progress == nil)
        #expect(status.result == nil)
        #expect(status.createdAt == nil)
        #expect(status.outcome == .running)
    }
}
