import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// v0141 W-DATAPARITY (P1) — locks the rebuilt Recovery source.
///
/// The old repository called the phantom `GET /api/insights/recovery` (404 → nil
/// → a permanently empty page). It now BUILDS the family from the shared
/// `GET /api/analytics?slice=summaries` slice (web parity —
/// `recovery-section.tsx`), per-block data-gated on `count > 0`. Covers:
/// - the family is built from the summaries slice (hits `/api/analytics`, NOT
///   `/api/insights/recovery`);
/// - the per-block gate: DAY_STRAIN + ENERGY_EXPENDITURE_KJ present, the absent
///   ANS_CHARGE / CARDIO_LOAD are NOT required — exactly those two blocks render;
/// - empty summaries → nil (honest empty state);
/// - a `403` (analytics gated) / `404` / `422` / transport error → nil.
@Suite("RecoveryInsights — built from analytics summaries (P1)", .serialized)
struct RecoveryInsightsRepositoryTests {
    private func makeAPI() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.14.1",
            buildNumber: "1"
        )
        return APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
    }

    /// One summaries-slice entry — a `TYPE` with a `count` and a `latest` value.
    private struct Entry {
        let type: String
        let count: Int
        let latest: Double
    }

    /// A summaries-slice body carrying only the given entries — everything else
    /// is absent (the operator's real shape).
    private func summariesBody(_ entries: [Entry]) -> Data {
        let inner = entries
            .map { "\"\($0.type)\":{\"count\":\($0.count),\"latest\":\($0.latest),\"mean\":\($0.latest)}" }
            .joined(separator: ",")
        return Data("{\"data\":{\"summaries\":{\(inner)}},\"error\":null}".utf8)
    }

    @Test("fetch — builds exactly the present blocks; hits /api/analytics not /insights/recovery")
    func fetchBuildsPresentBlocks() async throws {
        let repo = RecoveryInsightsRepository(api: makeAPI())
        nonisolated(unsafe) var capturedPath: String?
        nonisolated(unsafe) var capturedQuery: String?
        MockURLProtocol.handler = { [self] req in
            capturedPath = req.url?.path
            capturedQuery = req.url?.query
            // Operator shape: DAY_STRAIN + ENERGY_EXPENDITURE_KJ present, the
            // ANS_CHARGE / CARDIO_LOAD recovery members are absent.
            let body = summariesBody([
                Entry(type: "DAY_STRAIN", count: 50, latest: 12.4),
                Entry(type: "ENERGY_EXPENDITURE_KJ", count: 50, latest: 5400)
            ])
            return (
                HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                body
            )
        }

        let dto = try #require(await repo.fetch())
        // Repointed to the real source — NOT the phantom recovery route.
        #expect(capturedPath == "/api/analytics")
        #expect(capturedPath?.contains("insights/recovery") == false)
        #expect(capturedQuery?.contains("slice=summaries") == true)

        #expect(dto.status == "ok")
        #expect(dto.hasContent)
        // Exactly the two present blocks, in web render order — the absent
        // ANS_CHARGE / CARDIO_LOAD were NOT required.
        #expect(dto.items.map(\.id) == ["DAY_STRAIN", "ENERGY_EXPENDITURE_KJ"])
        #expect(!dto.items.contains { $0.id == "ANS_CHARGE" })
        #expect(!dto.items.contains { $0.id == "CARDIO_LOAD" })

        // Server value passes through verbatim; unit from the shared descriptor
        // (DAY_STRAIN is unitless → nil; ENERGY_EXPENDITURE_KJ → kJ).
        let strain = try #require(dto.items.first { $0.id == "DAY_STRAIN" })
        #expect(strain.value == 12.4)
        #expect(strain.unit == nil)
        // Label is the shared descriptor's localized display name — never blank.
        let strainLabel = try #require(strain.label)
        #expect(!strainLabel.isEmpty)
        let energy = try #require(dto.items.first { $0.id == "ENERGY_EXPENDITURE_KJ" })
        #expect(energy.value == 5400)
        #expect(energy.unit == "kJ")
    }

    @Test("fetch — empty summaries → nil (honest empty state)")
    func fetchEmptyIsNil() async {
        let repo = RecoveryInsightsRepository(api: makeAPI())
        MockURLProtocol.handler = { req in
            let body = Data("{\"data\":{\"summaries\":{}},\"error\":null}".utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        #expect(await repo.fetch() == nil)
    }

    @Test("fetch — a non-recovery type with data does NOT synthesise a block")
    func fetchIgnoresUnrelatedTypes() async {
        let repo = RecoveryInsightsRepository(api: makeAPI())
        MockURLProtocol.handler = { [self] req in
            let body = summariesBody([Entry(type: "WEIGHT", count: 200, latest: 82.5)])
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        #expect(await repo.fetch() == nil)
    }

    @Test("fetch — 403 (analytics gated) / 404 / 422 → nil")
    func fetchGatedIsNil() async {
        for status in [403, 404, 422] {
            let repo = RecoveryInsightsRepository(api: makeAPI())
            MockURLProtocol.handler = { req in
                (HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, Data())
            }
            #expect(await repo.fetch() == nil)
        }
    }

    // MARK: - Pure builder

    @Test("buildFamily — count 0 gates a block; latest falls back to mean; order is web order")
    func buildFamilyContract() {
        let summaries: [String: RecoverySummariesEnvelope.Stat] = [
            "ANS_CHARGE": .init(count: 0, latest: 99, mean: 99), // gated: count 0
            "DAY_STRAIN": .init(count: 12, latest: nil, mean: 8.0), // latest→mean fallback
            "AVERAGE_HEART_RATE": .init(count: 30, latest: 61, mean: 60)
        ]
        let dto = RecoveryInsightsRepository.buildFamily(from: summaries)
        #expect(dto.status == "ok")
        // ANS_CHARGE gated out (count 0); web order places DAY_STRAIN before HR.
        #expect(dto.items.map(\.id) == ["DAY_STRAIN", "AVERAGE_HEART_RATE"])
        #expect(dto.items.first { $0.id == "DAY_STRAIN" }?.value == 8.0)
        #expect(dto.items.first { $0.id == "AVERAGE_HEART_RATE" }?.value == 61)
    }

    @Test("buildFamily — no present recovery type → insufficient, no content")
    func buildFamilyEmpty() {
        let dto = RecoveryInsightsRepository.buildFamily(from: [:])
        #expect(dto.status == "insufficient")
        #expect(!dto.hasContent)
    }

    // MARK: - DTO HONEST-ONLY invariant

    @Test("DTO — an item with neither score nor value is not renderable (HONEST-ONLY)")
    func valuelessItemNotRenderable() {
        let item = RecoveryInsightsDTO.Item(id: "DAY_STRAIN")
        #expect(!item.hasValue)
        let dto = RecoveryInsightsDTO(status: "ok", items: [item])
        #expect(!dto.hasContent)
    }

    // MARK: - Store

    @MainActor
    @Test("store — load hydrates the family + presentableItems keeps valued rows")
    func storeLoadAndPresentable() async {
        let repo = RecoveryInsightsRepository(api: makeAPI())
        let store = RecoveryInsightsStore(repo: repo)
        MockURLProtocol.handler = { [self] req in
            let body = summariesBody([Entry(type: "DAY_STRAIN", count: 50, latest: 12.4)])
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        #expect(!store.hasSettledOnce)
        await store.load()
        #expect(store.hasSettledOnce)
        #expect(store.hasContent)
        #expect(store.presentableItems.map(\.id) == ["DAY_STRAIN"])
    }

    @MainActor
    @Test("store — empty endpoint settles with no content (honest empty state)")
    func storeEmptyState() async {
        let repo = RecoveryInsightsRepository(api: makeAPI())
        let store = RecoveryInsightsStore(repo: repo)
        MockURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
        }
        await store.load()
        #expect(store.hasSettledOnce)
        #expect(!store.hasContent)
        #expect(store.family == nil)
        #expect(store.presentableItems.isEmpty)
    }

    @MainActor
    @Test("store — clearOnLogout wipes the family")
    func storeClearOnLogout() async {
        let repo = RecoveryInsightsRepository(api: makeAPI())
        let store = RecoveryInsightsStore(repo: repo)
        MockURLProtocol.handler = { [self] req in
            let body = summariesBody([Entry(type: "DAY_STRAIN", count: 50, latest: 12.4)])
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        await store.load()
        #expect(store.hasContent)
        store.clearOnLogout()
        #expect(store.family == nil)
        #expect(!store.hasSettledOnce)
    }
}

// swiftlint:enable force_unwrapping
