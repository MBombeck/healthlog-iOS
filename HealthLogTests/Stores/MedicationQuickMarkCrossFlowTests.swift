import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping line_length

/// MEDS-QUICK-MARK-TAKEN — cross-flow integration: mark a pending intake
/// via the list-row quick-mark surface on `MedicationsScreen`, then load
/// the same medication's detail screen and verify the just-marked event
/// surfaces with `takenAt != nil && !skipped` in the paginated intake
/// history (the IntakeHistory card the operator sees).
///
/// The two stores (`MedicationsStore` for the list / today section,
/// `MedicationDetailStore` for the per-medication detail) share the same
/// server backend via separate repository calls. After a successful
/// quick-mark POST, the next GET to `/api/medications/[id]/intake` must
/// return the freshly-marked event — this is the contract the operator
/// experiences as "I tapped ✓ on the list and now the detail-screen
/// history shows the dose as taken".
@Suite("MedicationsStore × MedicationDetailStore — quick-mark cross-flow", .serialized)
struct MedicationQuickMarkCrossFlowTests {
    private static let scheduledISO = "2026-05-01T08:00:00Z"
    private static let takenISO = "2026-05-01T09:00:00Z"
    private static let medicationID = "med-X"
    private static let intakeID = "intake-X"

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

    private static func status(_ code: Int, request: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!,
            statusCode: code,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
    }

    /// POST /api/medications/intake JSON response body.
    private static func quickMarkResponse(intakeID: String, medID: String) -> String {
        "{\"data\":{\"id\":\"\(intakeID)\",\"medicationId\":\"\(medID)\",\"scheduledFor\":\"\(scheduledISO)\",\"takenAt\":\"\(takenISO)\",\"skipped\":false,\"snoozedUntil\":null}}"
    }

    /// GET /api/medications/[id]/intake JSON response body. `taken` flag
    /// drives whether the event surfaces with a real `takenAt` value.
    private static func intakeHistoryResponse(intakeID: String, taken: Bool) -> String {
        let takenAtJSON = taken ? "\"\(takenISO)\"" : "null"
        return "{\"data\":{\"events\":[{\"id\":\"\(intakeID)\",\"takenAt\":\(takenAtJSON),\"skipped\":false,\"scheduledFor\":\"\(scheduledISO)\",\"injectionSite\":null}],\"meta\":{\"total\":1,\"limit\":7,\"offset\":0}}}"
    }

    @Test("Quick-mark on list-row surfaces as taken in detail-screen IntakeHistory")
    @MainActor
    func quickMarkCrossFlowSucceeds() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        let medID = Self.medicationID
        let intakeID = Self.intakeID

        // Server-state simulator: starts with `taken == nil`, the POST flips
        // it to `taken`. Subsequent GET /intake reflects the new state.
        final class ServerState: @unchecked Sendable {
            var taken = false
        }
        let server = ServerState()

        MockURLProtocol.handler = { req in
            let path = req.url?.path ?? ""
            let method = req.httpMethod ?? "GET"

            if path == "/api/medications/intake", method == "POST" {
                server.taken = true
                return (Self.ok(req), Data(Self.quickMarkResponse(intakeID: intakeID, medID: medID).utf8))
            }

            if path == "/api/medications/\(medID)/intake", method == "GET" {
                let body = Self.intakeHistoryResponse(intakeID: intakeID, taken: server.taken)
                return (Self.ok(req), Data(body.utf8))
            }

            if path == "/api/medications/\(medID)/glp1", method == "GET" {
                // Non-GLP-1 medication — respond 404, MedicationDetailStore swallows it.
                return (Self.status(404, request: req), Data("{\"error\":\"not_found\"}".utf8))
            }

            return (Self.status(404, request: req), Data())
        }

        let repo = MedicationsRepository(api: api, outbox: outbox)

        let med = Medication(
            id: medID,
            name: "Lisinopril",
            dose: "5 mg",
            treatmentClass: "OTHER",
            category: nil,
            dosesPerUnit: nil,
            schedule: MedicationSchedule(times: []),
            lastTakenAt: nil,
            todayEventCount: 1,
            notificationsEnabled: true,
            active: true,
            archivedAt: nil
        )

        // STEP 1 — list-screen store gets a seeded today-intake row.
        let listStore = MedicationsStore(repo: repo)
        let scheduledAt = try #require(ISO8601DateFormatter().date(from: Self.scheduledISO))
        let takenAt = try #require(ISO8601DateFormatter().date(from: Self.takenISO))
        let pending = MedicationIntake(
            id: intakeID,
            medicationId: medID,
            scheduledAt: scheduledAt,
            takenAt: nil,
            status: .pending
        )
        listStore._testForceSet(todayIntakes: [pending])

        // STEP 2 — quick-mark via the list-row surface.
        let outcome = await listStore.markIntakeQuick(
            intakeId: intakeID,
            status: .taken,
            now: takenAt
        )
        #expect(outcome == .success, "Server-side flip should land cleanly")
        #expect(listStore.todayIntakes.first?.status == .taken)

        // STEP 3 — operator drills into the detail-screen for this med.
        let detailStore = MedicationDetailStore(medication: med, repo: repo)
        await detailStore.load()

        // STEP 4 — the freshly-marked event must surface as taken in the
        // paginated history list the detail-screen renders.
        #expect(detailStore.intakes.count == 1, "Detail screen should see the one intake event")
        let event = try #require(detailStore.intakes.first)
        #expect(event.id == intakeID, "Detail event-id matches the list-row intake-id")
        #expect(event.takenAt != nil, "Event must have a non-nil takenAt after the quick-mark")
        #expect(!event.skipped, "Event must NOT be marked as skipped")
    }

    @Test("Detail-screen still shows pending when no quick-mark fired yet")
    @MainActor
    func crossFlowControlPendingBeforeQuickMark() async throws {
        let api = makeAPI()
        let outbox = try OutboxQueue(inMemory: true)
        let medID = Self.medicationID
        let intakeID = Self.intakeID

        MockURLProtocol.handler = { req in
            let path = req.url?.path ?? ""
            let method = req.httpMethod ?? "GET"

            if path == "/api/medications/\(medID)/intake", method == "GET" {
                let body = Self.intakeHistoryResponse(intakeID: intakeID, taken: false)
                return (Self.ok(req), Data(body.utf8))
            }

            if path == "/api/medications/\(medID)/glp1", method == "GET" {
                return (Self.status(404, request: req), Data("{\"error\":\"not_found\"}".utf8))
            }

            return (Self.status(404, request: req), Data())
        }

        let repo = MedicationsRepository(api: api, outbox: outbox)
        let med = Medication(
            id: medID,
            name: "Lisinopril",
            dose: "5 mg",
            treatmentClass: "OTHER",
            category: nil,
            dosesPerUnit: nil,
            schedule: MedicationSchedule(times: []),
            lastTakenAt: nil,
            todayEventCount: 1,
            notificationsEnabled: true,
            active: true,
            archivedAt: nil
        )

        let detailStore = MedicationDetailStore(medication: med, repo: repo)
        await detailStore.load()

        #expect(detailStore.intakes.count == 1)
        let event = try #require(detailStore.intakes.first)
        #expect(event.takenAt == nil, "Event must remain untaken when no quick-mark fired")
        #expect(!event.skipped)
    }
}

// swiftlint:enable force_unwrapping line_length
