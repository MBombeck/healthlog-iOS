// Hosts the real paged scroll view in the test scene; the SPM library build
// has no app scene.
#if !SWIFT_PACKAGE && canImport(UIKit)

    import Foundation
    @testable import HealthLog
    import SwiftUI
    import Testing
    import UIKit

    // swiftlint:disable force_unwrapping

    /// **Paging does not reload a page whose data is there.**
    ///
    /// The real paged scroll view of Insights in a window, its pages wired to
    /// load exactly as a metric page loads (``InsightsMetricLoadTask``) from
    /// stores the pager model caches, against a counting fake server without
    /// a cache in front of it, so every load reaches the counter. Paging
    /// forward over every page and back again loads each metric page at most
    /// once: the first time it is built, never again on the way back.
    @MainActor
    @Suite("Insights paging loads each page once", .serialized, .mockURLSession)
    struct InsightsPagingLoadCountTests {
        private let ordered: [InsightsTabSelection] = [
            .overview,
            .metric(.bloodPressure),
            .metric(.weight),
            .metric(.pulse),
            .metric(.spo2),
            .metric(.steps),
            .special(.mood)
        ]

        @Test("forward over every page and back: at most one load per page")
        func pagingLoadsEachPageOnce() async throws {
            let requests = SeriesRequestCounter()
            MockURLProtocol.install { request in
                requests.record(request.url!)
                let body = #"{"data":null,"error":null}"#
                return (
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(body.utf8)
                )
            }
            let api = APIClient(
                environment: AppEnvironment(
                    baseURL: URL(string: "https://test.healthlog.local"),
                    bundleID: "dev.healthlog.app",
                    appVersion: "1.7.0",
                    buildNumber: "1"
                ),
                keychain: InMemoryKeychain(),
                sessionConfiguration: .mock()
            )
            let outbox = try OutboxQueue(inMemory: true)
            let pages = InsightsPagerPage.pages(from: ordered)
            let pager = InsightsPagerModel()
            pager.pagerOrder = ordered
            pager.realizeWindow(around: .overview, pages: pages)
            var loads: [MetricKind: Int] = [:]
            let view = LoadCountingPager(pager: pager, pages: pages, ordered: ordered) { kind in
                pager.chartStore(for: kind) {
                    ChartDetailStore(
                        kind: kind,
                        measurementsRepo: MeasurementsRepository(api: api, outbox: outbox),
                        insightsRepo: MetricInsightsRepository(api: api),
                        resolveLocale: { "de" }
                    )
                }
            } onLoad: { kind in
                loads[kind, default: 0] += 1
            }
            let host = UIHostingController(rootView: view)
            let scene = try #require(
                UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
                "the test host has no window scene"
            )
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
            window.rootViewController = host
            window.isHidden = false
            defer { window.isHidden = true }
            try await Self.settle(host, milliseconds: 400)

            // Forward over every page, the way a settled swipe lands: the
            // selection moves, the window of built pages grows, the scroll
            // follows. Each metric page is built and loads on the way.
            try await page(through: Array(ordered.dropFirst()), pager: pager, pages: pages, host: host)
            let afterFirstVisit = requests.seriesTypes()
            #expect(!afterFirstVisit.isEmpty, "no series was asked for: the pages did not load")
            // Back to the overview and forward again: every page holds its data.
            try await page(through: Array(ordered.dropLast().reversed()), pager: pager, pages: pages, host: host)
            try await page(through: Array(ordered.dropFirst()), pager: pager, pages: pages, host: host)

            for case let .metric(kind) in ordered {
                #expect(loads[kind] == 1, "\(kind) loaded \(loads[kind] ?? 0) times while paging")
            }
            // The server saw no series request on the way back and forth.
            #expect(requests.seriesTypes() == afterFirstVisit)
        }

        private func page(
            through selections: [InsightsTabSelection],
            pager: InsightsPagerModel,
            pages: [InsightsPagerPage],
            host: UIViewController
        ) async throws {
            for selection in selections {
                pager.selection = selection
                pager.realizeWindow(around: selection, pages: pages)
                pager.mirrorSelectionIntoScroll(selection, pages: pages, reduceMotion: true)
                try await Self.settle(host, milliseconds: 350)
                #expect(pager.scrolledID == InsightsPagerPage.page(for: selection, in: pages)?.scrollIdentity)
            }
        }

        private static func settle(_ host: UIViewController, milliseconds: Int) async throws {
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(milliseconds))
            host.view.layoutIfNeeded()
        }
    }

    /// The pager as the container builds it: the active page follows the
    /// selection, a metric page in the built window loads through
    /// ``InsightsMetricLoadTask``, every other page is a placeholder.
    private struct LoadCountingPager: View {
        let pager: InsightsPagerModel
        let pages: [InsightsPagerPage]
        let ordered: [InsightsTabSelection]
        let store: (MetricKind) -> ChartDetailStore
        let onLoad: (MetricKind) -> Void

        var body: some View {
            InsightsPagedScroll(
                pager: pager,
                pages: pages,
                liveOrderedSelections: ordered,
                activePage: InsightsPagerPage.page(for: pager.selection, in: pages)?.scrollIdentity
            ) { entry in
                if case let .flat(kind) = entry, pager.realizedMetrics.contains(kind) {
                    let store = store(kind)
                    Color.gray
                        .frame(height: 300)
                        .modifier(InsightsMetricLoadTask(store: store))
                        // Counts the loads the page starts, beside the
                        // requests the server sees.
                        .task(id: store.queryKey) { onLoad(kind) }
                        .id(kind)
                } else {
                    Color.clear.frame(height: 300)
                }
            }
        }
    }

    /// The `type` of every series request the fake server answered.
    private final class SeriesRequestCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [String: Int] = [:]

        func record(_ url: URL) {
            guard url.path.hasSuffix("/measurements/series") else { return }
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let type = items.first { $0.name == "type" || $0.name == "kind" }?.value ?? url.query ?? "?"
            lock.withLock { counts[type, default: 0] += 1 }
        }

        func seriesTypes() -> [String: Int] {
            lock.withLock { counts }
        }
    }

    // swiftlint:enable force_unwrapping

#endif
