import Foundation
@testable import HealthLog
import Testing

// swiftlint:disable force_unwrapping

/// DASHBOARD-TILE-COMPLETENESS — pin the synthesis pass that closes the
/// "großes Nichts" gap between the server `/api/dashboard/summary`
/// fast-path (which omits BP / Puls / Schlaf for many users) and the
/// chart-detail's `/api/measurements/series` source of truth.
///
/// Contract pinned:
/// 1. For every layout entry with `effectiveTileVisible == true` whose
///    kind maps to a `MetricKind`, AND which is missing from
///    `summary.metrics`, a placeholder `DashboardMetric` is appended
///    with `latestValue: nil`, empty sparkline, and the descriptor's
///    title + unit.
/// 2. Kinds already in `summary.metrics` are NOT duplicated.
/// 3. Non-metric widget ids (`mood`, `medications`, `bpInTarget`,
///    `achievements`, `vo2Max`) never synthesize tiles (no MetricKind).
/// 4. Idempotent: calling twice with the same inputs is a no-op on the
///    second call.
/// 5. No-op when `summary == nil`.
@Suite("DashboardStore.synthesiseMissingTiles — voll-umfänglich tile coverage", .serialized)
struct DashboardStoreSynthesiseMissingTilesTests {
    @MainActor
    private func makeStore() -> DashboardStore {
        let env = AppEnvironment(
            baseURL: URL(string: "https://test.healthlog.local")!,
            bundleID: "dev.healthlog.app",
            appVersion: "0.5.0",
            buildNumber: "1"
        )
        let kc = InMemoryKeychain()
        try? kc.setString("token", forKey: KeychainKey.authToken)
        let api = APIClient(environment: env, keychain: kc, sessionConfiguration: .mock())
        let repo = DashboardRepository(api: api)
        return DashboardStore(repo: repo)
    }

    private func metric(_ kind: MetricKind, latest: Double? = 70.0) -> DashboardMetric {
        DashboardMetric(
            id: kind.rawValue,
            kind: kind,
            title: kind.descriptor.title.key,
            latestValue: latest,
            secondaryValue: nil,
            unit: String(localized: kind.descriptor.unitLabel),
            trend: .flat,
            sparkline: [],
            updatedAt: nil
        )
    }

    private func summary(with metrics: [DashboardMetric]) -> DashboardSummary {
        DashboardSummary(
            greeting: Greeting(salutation: "Hi", date: Date(timeIntervalSince1970: 1_700_000_000)),
            compliance: ComplianceSnapshot(scheduledToday: 0, takenToday: 0),
            highlightInsight: nil,
            metrics: metrics,
            lastUpdated: nil
        )
    }

    @Test("Layout entries missing from summary become placeholder tiles")
    @MainActor
    func synthesisesMissingKinds() {
        let store = makeStore()
        // Server emitted only weight + bodyFat — every other tile-visible
        // layout entry should synthesise.
        store.seedSummaryForTesting(summary(with: [metric(.weight), metric(.bodyFat)]))
        store.synthesiseMissingTiles(layout: .default)
        let resolved = store.summary?.metrics.map(\.kind) ?? []
        let kinds = Set(resolved)
        // Default layout has tileVisible: true for all of these:
        #expect(kinds.contains(.weight))
        #expect(kinds.contains(.bodyFat))
        #expect(kinds.contains(.bloodPressure))
        #expect(kinds.contains(.pulse))
        #expect(kinds.contains(.sleep))
        #expect(kinds.contains(.steps))
        #expect(kinds.contains(.glucose))
        #expect(kinds.contains(.bodyWater))
        #expect(kinds.contains(.boneMass))
        #expect(kinds.contains(.spo2))
    }

    @Test("Synthesised placeholder carries nil latestValue + empty sparkline")
    @MainActor
    func placeholderShapeIsEmpty() {
        let store = makeStore()
        store.seedSummaryForTesting(summary(with: [metric(.weight)]))
        store.synthesiseMissingTiles(layout: .default)
        let bp = store.summary?.metrics.first(where: { $0.kind == .bloodPressure })
        #expect(bp != nil)
        #expect(bp?.latestValue == nil)
        #expect(bp?.sparkline.isEmpty == true)
        #expect(bp?.trend == .unknown)
    }

    @Test("Existing summary metrics survive unchanged")
    @MainActor
    func existingMetricsPreserved() {
        let store = makeStore()
        let weightTile = metric(.weight, latest: 72.4)
        let pulseTile = metric(.pulse, latest: 68)
        store.seedSummaryForTesting(summary(with: [weightTile, pulseTile]))
        store.synthesiseMissingTiles(layout: .default)
        let weightSurvivor = store.summary?.metrics.first(where: { $0.kind == .weight })
        let pulseSurvivor = store.summary?.metrics.first(where: { $0.kind == .pulse })
        #expect(weightSurvivor?.latestValue == 72.4)
        #expect(pulseSurvivor?.latestValue == 68)
        // No duplicate weight / pulse tiles.
        let weightCount = store.summary?.metrics.filter { $0.kind == .weight }.count ?? 0
        let pulseCount = store.summary?.metrics.filter { $0.kind == .pulse }.count ?? 0
        #expect(weightCount == 1)
        #expect(pulseCount == 1)
    }

    @Test("Calling twice is idempotent")
    @MainActor
    func idempotent() {
        let store = makeStore()
        store.seedSummaryForTesting(summary(with: [metric(.weight)]))
        store.synthesiseMissingTiles(layout: .default)
        let firstCount = store.summary?.metrics.count ?? 0
        store.synthesiseMissingTiles(layout: .default)
        let secondCount = store.summary?.metrics.count ?? 0
        #expect(firstCount == secondCount)
    }

    @Test("No-op when summary == nil")
    @MainActor
    func noOpOnEmptySummary() {
        let store = makeStore()
        store.synthesiseMissingTiles(layout: .default)
        #expect(store.summary == nil)
    }

    @Test("Non-tile-visible layout entries do NOT synthesise tiles")
    @MainActor
    func respectsTileVisibility() {
        let store = makeStore()
        store.seedSummaryForTesting(summary(with: []))
        // Layout where bloodPressure is hidden, weight is visible.
        let layout = DashboardWidgetLayout(widgets: [
            DashboardWidgetConfig(id: DashboardWidgetId.weight, visible: true, tileVisible: true, order: 0),
            DashboardWidgetConfig(id: DashboardWidgetId.bp, visible: true, tileVisible: false, order: 1)
        ])
        store.synthesiseMissingTiles(layout: layout)
        let kinds = Set(store.summary?.metrics.map(\.kind) ?? [])
        #expect(kinds.contains(.weight))
        #expect(!kinds.contains(.bloodPressure))
    }
}

// swiftlint:enable force_unwrapping
