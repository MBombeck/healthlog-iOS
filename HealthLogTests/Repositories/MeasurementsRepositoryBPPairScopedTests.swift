import Foundation

// swiftlint:disable force_unwrapping
import Testing

#if SWIFT_PACKAGE
    @testable import HealthLogCore
#else
    @testable import HealthLog
#endif

/// v0.14.10 BP-PAIR FIX regression suite.
///
/// `recent(kind: .bloodPressure)` used to route through the generic
/// kind-scoped fetch (`?type=BLOOD_PRESSURE_SYS` — BP's
/// `availabilitySummaryKey`), so the server page carried ONLY systolic rows
/// and `MeasurementAggregator.mergeBloodPressure` emitted
/// `.bloodPressure(systolic: s, diastolic: 0)` for every reading — the
/// operator-reported "Letzte Messung 124/0" on the Insights BP page + the
/// drill-down rows (chart stayed correct via the separate `/series` route).
/// These tests pin the fixed contract: the BP recent page fetches BOTH type
/// pages (SYS + DIA), merges them on `measuredAt`, and never loses the
/// diastolic component.
@Suite("MeasurementsRepository BP pair-scoped recent page", .serialized)
struct MeasurementsRepositoryBPPairScopedTests {
    private func makeRepo() throws -> MeasurementsRepository {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.1.0",
            buildNumber: "1"
        )
        let kc = InMemoryKeychain()
        let api = APIClient(environment: env, keychain: kc, sessionConfiguration: .mock())
        return try MeasurementsRepository(api: api, outbox: OutboxQueue(inMemory: true))
    }

    private func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    /// Lightweight per-row fixture (struct, not 4-tuple, per `large_tuple`).
    private struct WireRow {
        let id: String
        let type: String
        let value: Double
        let at: Date
    }

    private func listPayload(rows: [WireRow]) -> Data {
        let items = rows.map { row in
            """
            {"id":"\(row.id)","type":"\(row.type)","value":\(row.value),"measuredAt":"\(iso(row.at))"}
            """
        }
        return Data("{\"data\":{\"measurements\":[\(items.joined(separator: ","))]}}".utf8)
    }

    private static func queryValue(_ url: URL, _ name: String) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == name })?
            .value
    }

    @Test("BP recent page fetches SYS + DIA type pages and merges full pairs (124/82, never 124/0)")
    func pairedTypeScopedFetchMergesBothComponents() async throws {
        let repo = try makeRepo()
        let t1 = Date(timeIntervalSince1970: 1_780_000_000)
        let t2 = t1.addingTimeInterval(-3600)
        let sysPage = listPayload(rows: [
            WireRow(id: "sys-1", type: "BLOOD_PRESSURE_SYS", value: 124, at: t1),
            WireRow(id: "sys-2", type: "BLOOD_PRESSURE_SYS", value: 128, at: t2)
        ])
        let diaPage = listPayload(rows: [
            WireRow(id: "dia-1", type: "BLOOD_PRESSURE_DIA", value: 82, at: t1),
            WireRow(id: "dia-2", type: "BLOOD_PRESSURE_DIA", value: 84, at: t2)
        ])
        MockURLProtocol.handler = { req in
            let url = req.url!
            let type = Self.queryValue(url, "type")
            let payload: Data = switch type {
            case "BLOOD_PRESSURE_SYS": sysPage
            case "BLOOD_PRESSURE_DIA": diaPage
            default: Data("{\"data\":{\"measurements\":[]}}".utf8)
            }
            return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, payload)
        }

        let rows = try await repo.recent(kind: .bloodPressure, limit: 400)

        #expect(rows.count == 2)
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        guard case let .bloodPressure(s1, d1) = byID["sys-1"]?.value else {
            Issue.record("sys-1 is not a BP pair: \(String(describing: byID["sys-1"]?.value))")
            return
        }
        #expect(s1 == 124)
        #expect(d1 == 82)
        guard case let .bloodPressure(s2, d2) = byID["sys-2"]?.value else {
            Issue.record("sys-2 is not a BP pair: \(String(describing: byID["sys-2"]?.value))")
            return
        }
        #expect(s2 == 128)
        #expect(d2 == 84)
        // The regression shape: NO row may carry a 0 diastolic when the server
        // has the DIA half.
        for row in rows {
            if case let .bloodPressure(_, dia) = row.value {
                #expect(dia != 0)
            }
        }
        // The merged row must carry the diastolic peer id so BP edits keep
        // fanning out to both server rows (T-1 contract).
        #expect(byID["sys-1"]?.bloodPressureDiastolicId == "dia-1")
    }

    @Test("shared formatter renders the merged pair as sys/dia")
    func formatterRendersPair() {
        let measurement = Measurement(
            id: "m1",
            kind: .bloodPressure,
            recordedAt: .now,
            value: .bloodPressure(systolic: 124, diastolic: 82),
            note: nil,
            source: .manual,
            externalUUID: nil
        )
        #expect(MeasurementChronoModel.formattedValue(measurement, units: .standard) == "124/82 mmHg")
    }

    @Test("type-scoped failure falls back to the global page (pairs intact)")
    func fallbackToGlobalPageKeepsPairs() async throws {
        let repo = try makeRepo()
        let t1 = Date(timeIntervalSince1970: 1_780_000_000)
        let globalPage = listPayload(rows: [
            WireRow(id: "sys-1", type: "BLOOD_PRESSURE_SYS", value: 142, at: t1),
            WireRow(id: "dia-1", type: "BLOOD_PRESSURE_DIA", value: 91, at: t1)
        ])
        MockURLProtocol.handler = { req in
            let url = req.url!
            if Self.queryValue(url, "type") != nil {
                // Older deploy that rejects the `type` filter.
                return (HTTPURLResponse(url: url, statusCode: 422, httpVersion: nil, headerFields: nil)!, Data())
            }
            return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, globalPage)
        }

        let rows = try await repo.recent(kind: .bloodPressure, limit: 400)

        #expect(rows.count == 1)
        guard case let .bloodPressure(sys, dia) = rows.first?.value else {
            Issue.record("fallback row is not a BP pair")
            return
        }
        #expect(sys == 142)
        #expect(dia == 91)
    }
}

// swiftlint:enable force_unwrapping
