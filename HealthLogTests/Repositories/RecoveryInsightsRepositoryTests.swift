import CryptoKit
import Foundation
@testable import HealthLog
import SwiftData
import Testing

// swiftlint:disable force_unwrapping

/// **1.4 B3 — the recovery family from `GET /api/analytics?slice=summaries`.**
///
/// What the page may show is decided here, and three rules carry it:
/// - only a type with a reading in the last 30 days belongs to the family
///   (the server's `avg30` is `null` otherwise), so Alex's cardio recovery from
///   2024 or a heart rate that stopped in spring never stands on the page;
/// - `latest` and `avg30` pass through exactly as the server sent them;
/// - the server's `recoveryEmpty` decides why an empty page is empty.
///
/// Plus the HRV measure: SDNN without a current reading and RMSSD with one
/// means the HRV page shows RMSSD.
@Suite("RecoveryInsights — family from the summaries slice (1.4 B3)", .serialized, .mockURLSession)
struct RecoveryInsightsRepositoryTests {
    private func makeAPI() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "1.4.0",
            buildNumber: "1"
        )
        return APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
    }

    /// One summaries entry: a type with its count, newest value and 30-day mean
    /// (`nil` → JSON `null`, the server's "no reading in 30 days").
    struct Entry {
        let type: String
        var count = 30
        let latest: Double
        let avg30: Double?
    }

    /// How the slice carries `recoveryEmpty`.
    enum Reason {
        case absent
        case null
        case value(String)
    }

    static func body(_ entries: [Entry], reason: Reason = .null) -> Data {
        let inner = entries.map { entry in
            let avg30 = entry.avg30.map { "\($0)" } ?? "null"
            return "\"\(entry.type)\":{\"count\":\(entry.count),\"latest\":\(entry.latest),"
                + "\"mean\":\(entry.latest),\"avg7\":null,\"avg30\":\(avg30)}"
        }.joined(separator: ",")
        let tail = switch reason {
        case .absent: ""
        case .null: ",\"recoveryEmpty\":null"
        case let .value(value): ",\"recoveryEmpty\":\"\(value)\""
        }
        return Data("{\"data\":{\"summaries\":{\(inner)}\(tail),\"lastSeenByType\":{}},\"error\":null}".utf8)
    }

    private func serve(_ data: Data, status: Int = 200) {
        MockURLProtocol.install { req in
            (HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, data)
        }
    }

    /// Alex's account on 21.10.: WHOOP daily since June, cardio recovery last
    /// seen in 2024, SDNN until June, RMSSD daily.
    static let alex: [Entry] = [
        Entry(type: "RECOVERY_SCORE", count: 277, latest: 83, avg30: 71.4),
        Entry(type: "DAY_STRAIN", count: 139, latest: 12.4, avg30: 11.8),
        Entry(type: "AVERAGE_HEART_RATE", count: 139, latest: 66, avg30: 64.2),
        Entry(type: "MAX_HEART_RATE", count: 139, latest: 158, avg30: 151.6),
        Entry(type: "ENERGY_EXPENDITURE_KJ", count: 139, latest: 10460, avg30: 10203.5),
        Entry(type: "CARDIO_RECOVERY", count: 4, latest: 28, avg30: nil),
        Entry(type: "HEART_RATE_VARIABILITY", count: 412, latest: 44.1, avg30: nil),
        Entry(type: "HRV_RMSSD", count: 139, latest: 55.3, avg30: 52.7)
    ]

    @Test("reads the summaries slice and keeps the server's values unchanged, in page order")
    func readsTheSliceVerbatim() async throws {
        let repo = RecoveryInsightsRepository(api: makeAPI())
        nonisolated(unsafe) var path: String?
        nonisolated(unsafe) var query: String?
        let body = Self.body(Self.alex)
        MockURLProtocol.install { req in
            path = req.url?.path
            query = req.url?.query
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }

        let family = try #require(try await repo.fetch())
        #expect(path == "/api/analytics")
        #expect(query?.contains("slice=summaries") == true)
        #expect(family.items.map(\.id) == [
            "RECOVERY_SCORE", "DAY_STRAIN", "AVERAGE_HEART_RATE", "MAX_HEART_RATE", "ENERGY_EXPENDITURE_KJ"
        ])
        let energy = try #require(family.item(for: "ENERGY_EXPENDITURE_KJ"))
        #expect(energy.latest == 10460)
        #expect(energy.average30 == 10203.5)
        #expect(family.item(for: "DAY_STRAIN")?.average30 == 11.8)
    }

    @Test("a type without a reading in the last 30 days never joins the family")
    func staleTypesStayOff() {
        let summaries: [String: RecoverySummariesEnvelope.Stat] = [
            // Plenty of history, nothing in 30 days: the server sends avg30 null.
            "MAX_HEART_RATE": .init(count: 120, latest: 171, mean: 160, avg30: nil),
            "DAY_STRAIN": .init(count: 30, latest: 9.1, mean: 10, avg30: 10.4),
            // Cardio recovery has its own page, current or not.
            "CARDIO_RECOVERY": .init(count: 4, latest: 28, mean: 29, avg30: 28)
        ]
        let family = RecoveryInsightsRepository.buildFamily(from: summaries)
        #expect(family.items.map(\.id) == ["DAY_STRAIN"])
    }

    @Test("recoveryEmpty is the server's: a reason, null, or the general note on an older server")
    func recoveryEmptyPassesThrough() async throws {
        let cases: [(Reason, String?)] = [
            (.value("oura_permission"), "oura_permission"),
            (.value("general"), "general"),
            (.null, nil),
            (.absent, RecoverySummariesEnvelope.unreportedReason)
        ]
        for (reason, expected) in cases {
            let repo = RecoveryInsightsRepository(api: makeAPI())
            serve(Self.body([], reason: reason))
            let family = try #require(try await repo.fetch())
            #expect(family.emptyReason == expected, "\(reason)")
            #expect(!family.hasContent)
        }
    }

    @Test("an empty family is still a value: it carries the reason and the HRV decision")
    func emptyFamilyIsAValue() async throws {
        let repo = RecoveryInsightsRepository(api: makeAPI())
        serve(Self.body([
            Entry(type: "HEART_RATE_VARIABILITY", latest: 44, avg30: nil),
            Entry(type: "HRV_RMSSD", latest: 55, avg30: 52)
        ], reason: .value("general")))
        let family = try #require(try await repo.fetch())
        #expect(family.items.isEmpty)
        #expect(family.emptyReason == "general")
        #expect(family.hrvShowsRMSSD)
    }

    @Test(
        "the HRV page shows RMSSD only when SDNN has no current reading and RMSSD has",
        arguments: [
            (nil as Double?, 52.7 as Double?, true),
            (46.0, 52.7, false),
            (nil, nil, false),
            (46.0, nil, false)
        ]
    )
    func hrvMeasure(sdnn: Double?, rmssd: Double?, showsRMSSD: Bool) {
        var summaries: [String: RecoverySummariesEnvelope.Stat] = [
            "HRV_RMSSD": .init(count: 30, latest: 55, mean: 54, avg30: rmssd)
        ]
        summaries["HEART_RATE_VARIABILITY"] = .init(count: 400, latest: 44, mean: 45, avg30: sdnn)
        #expect(RecoveryInsightsRepository.hrvShowsRMSSD(in: summaries) == showsRMSSD)
        // 1.4 B4 — an account that never had SDNN shows its RMSSD on the HRV
        // page whether or not the last reading is recent: there is no SDNN
        // series the page could show instead.
        summaries["HEART_RATE_VARIABILITY"] = nil
        #expect(RecoveryInsightsRepository.hrvShowsRMSSD(in: summaries))
        summaries["HRV_RMSSD"] = nil
        #expect(!RecoveryInsightsRepository.hrvShowsRMSSD(in: summaries), "no HRV of either kind")
    }

    @Test("1.4 B4: an RMSSD-only wearable lights the HRV page")
    func rmssdLightsTheHRVPage() {
        #expect(InsightsContainerScreen.pageKinds(for: [.hrvRMSSD, .dayStrain]).contains(.hrv))
        #expect(!InsightsContainerScreen.pageKinds(for: [.pulse]).contains(.hrv))
    }

    @Test("403, 404 and 422 are the calm empty state, not an error")
    func gatedIsNil() async throws {
        for status in [403, 404, 422] {
            let repo = RecoveryInsightsRepository(api: makeAPI())
            serve(Data(), status: status)
            #expect(try await repo.fetch() == nil, "\(status)")
        }
    }

    @Test("a failed read throws instead of passing for an empty page")
    func failureThrows() async {
        let repo = RecoveryInsightsRepository(api: makeAPI())
        serve(Data("{\"data\":null,\"error\":\"boom\"}".utf8), status: 500)
        await #expect(throws: (any Error).self) { try await repo.fetch() }
    }

    /// **The update path.** 1.3 cached its card family under
    /// `insightsRecovery:<day>` in its own shape (status, items with `value`),
    /// fresh for 24 hours. A phone updating to 1.4 in the middle of that day
    /// must show the server's current family, never 1.3's cards (Alex's
    /// cardio recovery from 2024 among them).
    @Test("a family cached by 1.3 is never served to 1.4; the slice is read instead")
    func familyCachedBy13IsNotServed() async throws {
        let container = try SWRCache.makeInMemory()
        let day = BerlinDayKey.string()
        let legacyHash = SHA256.hash(data: Data("insightsRecovery:\(day)".utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let legacyPayload = Data("""
        {"status":"ok","asOf":"2026-10-21T05:00:00.000Z","reason":null,"items":[\
        {"id":"CARDIO_RECOVERY","label":"Cardio recovery","value":28,"unit":"bpm"},\
        {"id":"DAY_STRAIN","label":"Day strain","value":9.1,"unit":null}]}
        """.utf8)
        let context = ModelContext(container)
        context.insert(CachedSnapshot(keyHash: legacyHash, payloadData: legacyPayload, updatedAt: .now.addingTimeInterval(-60)))
        try context.save()
        #expect(CacheKey.insightsRecovery(day: day).persistentHash != legacyHash)

        let swr = SWRCoordinator(cache: SWRCache(modelContainer: container), reachability: Online())
        nonisolated(unsafe) var requests = 0
        let body = Self.body(Self.alex)
        MockURLProtocol.install { req in
            requests += 1
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }

        let family = try #require(try await RecoveryInsightsRepository(api: makeAPI(), swr: swr).fetch())
        #expect(requests == 1)
        #expect(family.item(for: "CARDIO_RECOVERY") == nil)
        #expect(family.item(for: "DAY_STRAIN")?.latest == 12.4)
        #expect(family.items.first?.id == "RECOVERY_SCORE")
    }

    private final class Online: ReachabilityProviding, @unchecked Sendable {
        var isOnlineStream: AsyncStream<Bool> {
            get async {
                AsyncStream { continuation in
                    continuation.yield(true)
                    continuation.finish()
                }
            }
        }

        func isCurrentlyOnline() async -> Bool {
            true
        }
    }
}

/// **1.4 B3 — the store: family, trend lines, HRV measure, honest failure.**
@MainActor
@Suite("RecoveryInsightsStore — trend lines and the HRV measure (1.4 B3)", .serialized, .mockURLSession)
struct RecoveryInsightsStoreTests {
    private func makeAPI() -> APIClient {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "1.4.0",
            buildNumber: "1"
        )
        return APIClient(environment: env, keychain: InMemoryKeychain(), sessionConfiguration: .mock())
    }

    private func serve(_ data: Data, status: Int = 200) {
        MockURLProtocol.install { req in
            (HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, data)
        }
    }

    /// Records the kinds whose lines the store asked for.
    final class Requests: @unchecked Sendable {
        var kinds: [MetricKind] = []
    }

    @Test("loads the lines of the two trend cards and nothing else")
    func loadsTrendLines() async {
        let requests = Requests()
        let store = RecoveryInsightsStore(repo: RecoveryInsightsRepository(api: makeAPI())) { kind in
            requests.kinds.append(kind)
            return [HealthLog.Measurement(id: "m-\(kind.rawValue)", kind: kind, recordedAt: .now, value: .scalar(1))]
        }
        serve(RecoveryInsightsRepositoryTests.body(RecoveryInsightsRepositoryTests.alex))
        await store.load()
        #expect(requests.kinds == [.recoveryScore, .dayStrain])
        #expect(store.trendReadings[.dayStrain]?.count == 1)
        #expect(store.trendReadings[.averageHeartRate] == nil)
        #expect(store.hasContent)
        #expect(!store.loadFailed)
    }

    @Test("the HRV page shows RMSSD once SDNN stopped; every other page shows itself")
    func hrvDisplayKind() async {
        let store = RecoveryInsightsStore(repo: RecoveryInsightsRepository(api: makeAPI()))
        #expect(store.displayKind(for: .hrv) == .hrv)
        serve(RecoveryInsightsRepositoryTests.body(RecoveryInsightsRepositoryTests.alex))
        await store.load()
        #expect(store.displayKind(for: .hrv) == .hrvRMSSD)
        #expect(store.displayKind(for: .pulse) == .pulse)
        #expect(store.displayKind(for: .restingHeartRate) == .restingHeartRate)
    }

    @Test("a failed first load is a failure, not an empty page; a refresh recovers")
    func failureIsNotEmpty() async {
        let store = RecoveryInsightsStore(repo: RecoveryInsightsRepository(api: makeAPI()))
        serve(Data("{\"data\":null,\"error\":\"boom\"}".utf8), status: 500)
        await store.load()
        #expect(store.hasSettledOnce)
        #expect(store.loadFailed)
        #expect(store.family == nil)

        serve(RecoveryInsightsRepositoryTests.body(RecoveryInsightsRepositoryTests.alex))
        await store.refresh()
        #expect(!store.loadFailed)
        #expect(store.hasContent)
    }

    @Test("a failed refresh keeps the page that is on screen")
    func refreshFailureKeepsFamily() async {
        let store = RecoveryInsightsStore(repo: RecoveryInsightsRepository(api: makeAPI()))
        serve(RecoveryInsightsRepositoryTests.body(RecoveryInsightsRepositoryTests.alex))
        await store.load()
        serve(Data("{\"data\":null,\"error\":\"boom\"}".utf8), status: 500)
        await store.refresh()
        #expect(store.hasContent)
        #expect(!store.loadFailed)
    }

    @Test("logout clears family and lines")
    func clearOnLogout() async {
        let store = RecoveryInsightsStore(repo: RecoveryInsightsRepository(api: makeAPI())) { kind in
            [HealthLog.Measurement(id: "m-\(kind.rawValue)", kind: kind, recordedAt: .now, value: .scalar(1))]
        }
        serve(RecoveryInsightsRepositoryTests.body(RecoveryInsightsRepositoryTests.alex))
        await store.load()
        store.clearOnLogout()
        #expect(store.family == nil)
        #expect(store.trendReadings.isEmpty)
        #expect(!store.hasSettledOnce)
    }
}

// swiftlint:enable force_unwrapping
