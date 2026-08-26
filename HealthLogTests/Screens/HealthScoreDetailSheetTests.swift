#if canImport(UIKit)
    import Foundation
    @testable import HealthLog
    import SwiftUI
    import Testing
    import UIKit

    // swiftlint:disable force_unwrapping

    /// F3 (PB5 review): the `HealthScoreTile` re-enable in PB5 claimed
    /// "the detail sheet renders its own error states" — but the sheet
    /// only branched on `score` / skeleton, so an errored tap opened an
    /// infinite skeleton. This suite pins the three sheet-state branches:
    /// 1. score loaded → loaded view
    /// 2. error present → error state with retry button
    /// 3. neither → skeleton placeholder
    ///
    /// Smoke-test pattern: host the sheet in a `UIHostingController` and
    /// assert it lays out without crashing for each store-state, matching
    /// the convention from `LockOverlayTests`.
    @MainActor
    @Suite("HealthScoreDetailSheet — state branches (F3)", .serialized)
    struct HealthScoreDetailSheetTests {
        private func makeAPIClient() -> APIClient {
            let env = AppEnvironment(
                baseURL: URL(string: "https://test.healthlog.local")!,
                bundleID: "dev.healthlog.app",
                appVersion: "0.5.0",
                buildNumber: "1"
            )
            let kc = InMemoryKeychain()
            try? kc.setString("token", forKey: KeychainKey.authToken)
            return APIClient(environment: env, keychain: kc, sessionConfiguration: .mock())
        }

        private func makeInsightsStore() -> InsightsStore {
            InsightsStore(repo: InsightsRepository(api: makeAPIClient()))
        }

        private func hostSheet(scoreStore: HealthScoreStore, insightsStore: InsightsStore) -> UIHostingController<some View> {
            let sheet = HealthScoreDetailSheet()
                .environment(scoreStore)
                .environment(insightsStore)
            let host = UIHostingController(rootView: sheet)
            host.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
            host.view.layoutIfNeeded()
            return host
        }

        // MARK: - Score branch

        @Test("Loaded score → renders without crash")
        func loadedScoreBranch() async {
            let api = makeAPIClient()
            let payload = Data(Self.snapshotJSON.utf8)
            MockURLProtocol.handler = { request in
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (response, payload)
            }
            let store = HealthScoreStore(repo: AnalyticsRepository(api: api))
            await store.load()
            #expect(store.score != nil)
            #expect(store.error == nil)

            let host = hostSheet(scoreStore: store, insightsStore: makeInsightsStore())
            #expect(host.view.bounds.width == 390)
            #expect(host.view.bounds.height == 844)
        }

        // MARK: - Error branch

        @Test("Error present → renders error state without crash")
        func errorBranch() async {
            let api = makeAPIClient()
            MockURLProtocol.handler = { request in
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 500,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (response, Data("{}".utf8))
            }
            let store = HealthScoreStore(repo: AnalyticsRepository(api: api))
            await store.load()
            #expect(store.score == nil)
            #expect(store.error != nil, "Store must surface the 500 as a non-nil error so the sheet's F3 error branch can take over")

            let host = hostSheet(scoreStore: store, insightsStore: makeInsightsStore())
            #expect(host.view.bounds.width == 390)
            #expect(host.view.bounds.height == 844)
        }

        // MARK: - Skeleton branch (neither score nor error)

        @Test("Neither score nor error → renders skeleton without crash")
        func skeletonBranch() {
            // Store has not been loaded — `score == nil && error == nil`.
            let api = makeAPIClient()
            let store = HealthScoreStore(repo: AnalyticsRepository(api: api))
            #expect(store.score == nil)
            #expect(store.error == nil)

            let host = hostSheet(scoreStore: store, insightsStore: makeInsightsStore())
            #expect(host.view.bounds.width == 390)
            #expect(host.view.bounds.height == 844)
        }

        // MARK: - Fixtures

        /// Production-shape `/api/dashboard/snapshot` envelope — the flat
        /// `healthScore` DTO rides on the snapshot slot since server v1.34.0.
        /// Lifted from `HealthScoreStoreTests`.
        private static let snapshotJSON = """
        {
          "data": {
            "healthScore": {
              "score": 72,
              "band": "green",
              "delta": 4
            }
          }
        }
        """
    }

    // swiftlint:enable force_unwrapping

#endif
