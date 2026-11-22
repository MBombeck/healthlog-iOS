import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// A failed load reads as a failure with a retry, never as "nothing here yet";
/// a link from outside closes only a form that holds no input; a linked record
/// lands in the range that shows it.
@MainActor
@Suite("Screen load states", .serialized, .mockURLSession)
struct ScreenLoadStateTests {
    // MARK: - Illness insights

    @Test("A failed insights request is the error state, not the empty one")
    func insightsFailureIsError() {
        let phase = IllnessInsightsScreen.phase(hasEpisodes: false, hasLoaded: true, isLoading: false, loadFailed: true)
        #expect(phase == .failed)
    }

    @Test("Before the first answer the insights show the loading state")
    func insightsLoading() {
        #expect(IllnessInsightsScreen.phase(hasEpisodes: false, hasLoaded: false, isLoading: false, loadFailed: false) == .loading)
        #expect(IllnessInsightsScreen.phase(hasEpisodes: false, hasLoaded: true, isLoading: true, loadFailed: false) == .loading)
    }

    @Test("Insights without episodes are empty, with episodes loaded")
    func insightsEmptyAndLoaded() {
        #expect(IllnessInsightsScreen.phase(hasEpisodes: false, hasLoaded: true, isLoading: false, loadFailed: false) == .empty)
        #expect(IllnessInsightsScreen.phase(hasEpisodes: true, hasLoaded: true, isLoading: false, loadFailed: true) == .loaded)
    }

    private func makeIllnessStore() throws -> IllnessStore {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.14.10",
            buildNumber: "1"
        )
        let keychain = InMemoryKeychain()
        try? keychain.setString("token", forKey: KeychainKey.authToken)
        let api = APIClient(environment: env, keychain: keychain, sessionConfiguration: .mock())
        return try IllnessStore(repository: IllnessRepository(api: api, outbox: OutboxQueue(inMemory: true)))
    }

    private nonisolated static let insightsBody = #"""
    {"data":{"windowDays":365,"episodeCount":3,"resolvedCount":2,"typicalRecoveryGapDays":null,
    "gapSampleSize":0,"byMonth":{},"byType":{}},"error":null}
    """#

    @Test("A failed refresh keeps the summary on screen and records the failure")
    func insightsRefreshFailureKeepsSummary() async throws {
        let store = try makeIllnessStore()
        MockURLProtocol.install { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(Self.insightsBody.utf8))
        }
        await store.loadInsights(includeRecoveryGap: true)
        #expect(store.insights?.episodeCount == 3)
        #expect(store.insightsError == nil)

        MockURLProtocol.install { req in
            let body = Data(#"{"data":null,"error":{"code":"BAD_REQUEST","message":"Nope"}}"#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!, body)
        }
        await store.loadInsights(includeRecoveryGap: true)
        #expect(store.insights?.episodeCount == 3, "the loaded summary stays")
        #expect(store.insightsError != nil)
        #expect(store.hasLoadedInsights)
        #expect(store.isLoadingInsights == false)
    }

    @Test("A first insights request that fails ends in the error phase")
    func insightsFirstFailureIsErrorPhase() async throws {
        let store = try makeIllnessStore()
        MockURLProtocol.install { req in
            let body = Data(#"{"data":null,"error":{"code":"BAD_REQUEST","message":"Nope"}}"#.utf8)
            return (HTTPURLResponse(url: req.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!, body)
        }
        await store.loadInsights(includeRecoveryGap: true)
        let phase = IllnessInsightsScreen.phase(
            hasEpisodes: (store.insights?.episodeCount ?? 0) > 0,
            hasLoaded: store.hasLoadedInsights,
            isLoading: store.isLoadingInsights,
            loadFailed: store.insightsError != nil
        )
        #expect(phase == .failed)
    }

    // MARK: - Custom metrics

    @Test("A custom-metric list that failed to load is not the empty list")
    func customMetricsFailureIsNotEmpty() {
        #expect(CustomMetricsListScreen.showsLoadFailure(isEmpty: true, isLoading: false, lastError: "offline"))
        #expect(!CustomMetricsListScreen.showsLoadFailure(isEmpty: true, isLoading: false, lastError: nil))
        #expect(!CustomMetricsListScreen.showsLoadFailure(isEmpty: true, isLoading: true, lastError: "offline"))
        #expect(!CustomMetricsListScreen.showsLoadFailure(isEmpty: false, isLoading: false, lastError: "offline"))
    }

    // MARK: - Deep links

    @Test("A link applied while signed in is counted, a parked one when it lands")
    func deepLinkArrivalIsCounted() {
        let router = AppRouter()
        router.apply(.dashboard, isAuthenticated: true)
        #expect(router.deepLinkArrivalCount == 1)

        router.apply(.dashboard, isAuthenticated: false)
        #expect(router.deepLinkArrivalCount == 1, "a parked route has not arrived yet")
        router.consumePendingRoute()
        #expect(router.deepLinkArrivalCount == 2)
    }

    @Test("Only a form without input or a running save closes for a link")
    func onlyCleanFormsClose() {
        #expect(HLDiscardGuard.closesForDeepLink(isDirty: false, isSaving: false))
        #expect(!HLDiscardGuard.closesForDeepLink(isDirty: true, isSaving: false))
        #expect(!HLDiscardGuard.closesForDeepLink(isDirty: false, isSaving: true))
    }

    @Test("A linked record shows in a range that contains it")
    func linkedRecordPicksItsRange() {
        #expect(PersonalRecordsScreen.bucket(showing: .year, current: .week) == .year)
        #expect(PersonalRecordsScreen.bucket(showing: .week, current: .allTime) == .allTime)
        #expect(PersonalRecordsScreen.bucket(showing: .month, current: .month) == .month)
    }
}
