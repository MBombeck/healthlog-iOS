import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// **Build 6.3 — batched card compliance.**
///
/// Drives the REAL `APIClient` through `MockURLProtocol` (PROJECT_GUIDE.md rule) so the
/// `GET /api/medications/compliance` batch decode goes over the production path
/// — catching envelope / field-name drift. Locks that one round trip warms the
/// card snapshots and reports the covered ids so the caller fans out only over
/// the remainder.
@MainActor
@Suite("Medication batch compliance — Build 6.3", .serialized)
struct MedicationComplianceBatchTests {
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

    @Test("complianceSummary decodes the batch array + populates card snapshots")
    func batchPopulatesSnapshots() async throws {
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MedicationsRepository(api: makeClient(), outbox: outbox)
        let store = MedicationsStore(repo: repo)

        nonisolated(unsafe) var capturedPath: String?
        MockURLProtocol.handler = { req in
            capturedPath = req.url?.path
            let json = #"""
            {"data":[
              {"medicationId":"med-1",
               "compliance7":{"totalExpected":7,"taken":6,"skipped":0,"missed":1,"rate":86,"streak":3},
               "compliance30":{"totalExpected":30,"taken":24,"skipped":2,"missed":4,"rate":80,"streak":3},
               "complianceDisplay":{"shortDays":7,"longDays":30,"short":{"rate":86,"streak":3},"long":{"rate":80}}}
            ]}
            """#
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(json.utf8)
            )
        }

        let covered = await store.refreshCardComplianceViaBatch()

        #expect(capturedPath == "/api/medications/compliance")
        #expect(covered == ["med-1"])
        let snap = try #require(store.complianceCardSnapshots["med-1"])
        #expect(snap.rate7 == 86)
        #expect(snap.rate30 == 80)
        #expect(snap.displayShortDays == 7)
        #expect(snap.displayLongDays == 30)
        #expect(snap.displayShortRate == 86)
        #expect(snap.displayLongRate == 80)
    }

    @Test("A batch failure returns an empty covered set so the fan-out runs")
    func batchFailureFallsBack() async throws {
        let outbox = try OutboxQueue(inMemory: true)
        let repo = MedicationsRepository(api: makeClient(), outbox: outbox)
        let store = MedicationsStore(repo: repo)

        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!, nil)
        }
        let covered = await store.refreshCardComplianceViaBatch()
        #expect(covered.isEmpty, "a failed batch must yield no covered ids so the per-med fan-out runs")
    }
}
