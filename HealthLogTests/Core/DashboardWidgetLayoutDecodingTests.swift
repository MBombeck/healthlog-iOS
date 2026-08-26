import Foundation
@testable import HealthLog
import Testing

/// Decoder tests against the wire shape emitted by
/// `src/app/api/dashboard/widgets/route.ts`. Captures the server contract
/// so a future server change to the layout JSON shape can't slip past
/// silently the way the v0.3.0 schema-drift bugs did.
@Suite("DashboardWidgetLayout decoding")
struct DashboardWidgetLayoutDecodingTests {
    /// Captured from `serializeDashboardLayout` (server source) — what a
    /// fresh user with the merged-default layout sees on the first GET.
    private static let defaultLayoutFixture = #"""
    {
      "version": 1,
      "widgets": [
        { "id": "weight", "visible": true, "tileVisible": true, "order": 0 },
        { "id": "bp", "visible": true, "tileVisible": true, "order": 1 },
        { "id": "pulse", "visible": true, "tileVisible": true, "order": 2 },
        { "id": "bodyFat", "visible": true, "tileVisible": true, "order": 3 },
        { "id": "mood", "visible": true, "tileVisible": true, "order": 4 },
        { "id": "bpInTarget", "visible": true, "tileVisible": true, "order": 5 },
        { "id": "medications", "visible": true, "tileVisible": true, "order": 6 },
        { "id": "sleep", "visible": false, "tileVisible": false, "order": 7 },
        { "id": "steps", "visible": false, "tileVisible": false, "order": 8 },
        { "id": "glucose", "visible": false, "tileVisible": false, "order": 9 },
        { "id": "totalBodyWater", "visible": false, "tileVisible": false, "order": 10 },
        { "id": "boneMass", "visible": false, "tileVisible": false, "order": 11 },
        { "id": "oxygenSaturation", "visible": false, "tileVisible": false, "order": 12 },
        { "id": "achievements", "visible": true, "tileVisible": false, "order": 13 },
        { "id": "vo2Max", "visible": false, "tileVisible": false, "order": 14 }
      ],
      "comparisonBaseline": "none",
      "chartOverlayPrefs": {}
    }
    """#

    /// Legacy save where the row predates `tileVisible` — server's resolver
    /// fills it in by mirroring `visible`, but in case it leaks through we
    /// want iOS to apply the same fallback.
    private static let legacyTileVisibleMissingFixture = #"""
    {
      "version": 1,
      "widgets": [
        { "id": "weight", "visible": true, "order": 0 }
      ]
    }
    """#

    @Test("decodes the v1.4.27 default layout fixture")
    func decodesDefaultLayout() throws {
        let data = Data(Self.defaultLayoutFixture.utf8)
        let layout = try JSONDecoder.hlDefault.decode(DashboardWidgetLayout.self, from: data)
        #expect(layout.version == 1)
        #expect(layout.widgets.count == 15)
        // Spot-check a few rows.
        let weight = try #require(layout.widgets.first { $0.id == "weight" })
        #expect(weight.effectiveTileVisible == true)
        let sleep = try #require(layout.widgets.first { $0.id == "sleep" })
        #expect(sleep.effectiveTileVisible == false)
        let achievements = try #require(layout.widgets.first { $0.id == "achievements" })
        // achievements has visible: true but tileVisible: false → no tile.
        #expect(achievements.effectiveTileVisible == false)
        #expect(achievements.visible == true)
    }

    @Test("effectiveTileVisible falls back to visible when tileVisible absent")
    func legacyTileVisibleFallback() throws {
        let data = Data(Self.legacyTileVisibleMissingFixture.utf8)
        let layout = try JSONDecoder.hlDefault.decode(DashboardWidgetLayout.self, from: data)
        let row = try #require(layout.widgets.first)
        #expect(row.tileVisible == nil)
        #expect(row.effectiveTileVisible == true)
    }

    @Test("visibleTiles returns only tile-visible rows, sorted by order")
    func visibleTilesOrdered() throws {
        let data = Data(Self.defaultLayoutFixture.utf8)
        let layout = try JSONDecoder.hlDefault.decode(DashboardWidgetLayout.self, from: data)
        let visible = layout.visibleTiles
        // Default: weight, bp, pulse, bodyFat, mood, bpInTarget, medications.
        #expect(visible.count == 7)
        #expect(visible.map(\.id) == ["weight", "bp", "pulse", "bodyFat", "mood", "bpInTarget", "medications"])
    }

    @Test("toggleTileVisibility flips a known row")
    func toggleTileVisibility() {
        // v0.4.1: defaults are now tile-visible by default. Use achievements
        // (which intentionally stays `tileVisible: false` in the iOS default
        // because it has a dedicated tile, not a metric tile) for the flip
        // assertion so the test exercises both directions.
        let layout = DashboardWidgetLayout.default
        let before = layout.widgets.first { $0.id == "achievements" }
        let after = layout.togglingTileVisibility(forId: "achievements").widgets.first { $0.id == "achievements" }
        #expect(before?.effectiveTileVisible == false)
        #expect(after?.effectiveTileVisible == true)
    }

    /// Regression test for the M2-A1 audit finding: every MetricKind-backed
    /// widget id in `DashboardWidgetLayout.default` is tile-visible. Before
    /// v0.4.1 seven metric kinds shipped hidden, collapsing the dashboard
    /// to four tiles on a fresh install. If anyone re-flips a row, this
    /// test points at the regression.
    @Test("default layout makes every MetricKind tile visible")
    func defaultLayoutShowsEveryMetricKindTile() {
        let layout = DashboardWidgetLayout.default
        for kind in MetricKind.allCases {
            guard let widgetId = DashboardWidgetId.id(forMetricKind: kind) else { continue }
            let row = layout.widgets.first { $0.id == widgetId }
            #expect(
                row?.effectiveTileVisible == true,
                "MetricKind \(kind) (widget id \(widgetId)) must be tile-visible by default"
            )
        }
    }

    @Test("visibleTiles on the iOS default exposes every MetricKind plus non-metric pins")
    func defaultLayoutVisibleTilesIncludesAllMetricKinds() {
        let visibleIds = Set(DashboardWidgetLayout.default.visibleTiles.map(\.id))
        // Every MetricKind-backed widget must be in visibleTiles.
        for kind in MetricKind.allCases {
            guard let widgetId = DashboardWidgetId.id(forMetricKind: kind) else { continue }
            #expect(visibleIds.contains(widgetId), "Widget \(widgetId) missing from visibleTiles")
        }
        // Non-metric pins that the dashboard surfaces elsewhere stay visible.
        #expect(visibleIds.contains(DashboardWidgetId.mood))
        #expect(visibleIds.contains(DashboardWidgetId.bpInTarget))
        #expect(visibleIds.contains(DashboardWidgetId.medications))
        // vo2Max is now a MetricKind-backed widget (v0.5.2 F2) — still
        // ships visible by default just like before.
        #expect(visibleIds.contains(DashboardWidgetId.vo2Max))
        // achievements stays hidden by default (has a dedicated tile, not
        // a metric tile).
        #expect(visibleIds.contains(DashboardWidgetId.achievements) == false)
    }

    /// Order-contract: the default layout's tile-strip ordering for the
    /// 10 supported MetricKinds matches the documented sequence:
    /// vital primaries first (weight / BP / pulse / bodyFat), then the
    /// background-sync MetricKinds in the order their HK frequencies +
    /// medical-relevance dictate. If anyone re-orders this without updating
    /// the test, the snapshot diff makes the change explicit.
    @Test("default layout MetricKind-tile order matches the documented sequence")
    func defaultLayoutMetricKindOrder() {
        let visibleMetricIds = DashboardWidgetLayout.default
            .visibleTiles
            .map(\.id)
            .filter { DashboardWidgetId.metricKind(forId: $0) != nil }
        #expect(visibleMetricIds == [
            DashboardWidgetId.weight,
            DashboardWidgetId.bp,
            DashboardWidgetId.pulse,
            DashboardWidgetId.bodyFat,
            // Build 7 / item 7.3 — mood graduated to a metric tile (order 4 in
            // the default layout, between bodyFat and bpInTarget), so it now
            // appears in the metric-id tile order.
            DashboardWidgetId.mood,
            DashboardWidgetId.sleep,
            DashboardWidgetId.steps,
            DashboardWidgetId.glucose,
            DashboardWidgetId.totalBodyWater,
            DashboardWidgetId.boneMass,
            DashboardWidgetId.oxygenSaturation,
            DashboardWidgetId.vo2Max,
            // v0.5.2 F2 — appended in HK-completeness-order: cardio first
            // (RHR + HRV), then vitals (bodyTemperature), then mobility
            // (walkingSpeed / asymmetry / stepLength), then body-composition (BMI).
            DashboardWidgetId.restingHeartRate,
            DashboardWidgetId.hrv,
            DashboardWidgetId.bodyTemperature,
            DashboardWidgetId.walkingSpeed,
            DashboardWidgetId.walkingAsymmetry,
            DashboardWidgetId.walkingStepLength,
            DashboardWidgetId.bmi,
            // v0.7.0 HK adopt-and-stream — fourth gait metric, then
            // respiratory rate, then the two audio-exposure readings.
            DashboardWidgetId.walkingDoubleSupport,
            DashboardWidgetId.respiratoryRate,
            DashboardWidgetId.audioExposureEnvironment,
            DashboardWidgetId.audioExposureHeadphone,
            // v0158 — v1.25 clinical measurement types, appended in catalogue
            // order. Tile-visible by default (H2 fix) per the every-MetricKind
            // invariant; the empty-tile policy keeps them off a fresh grid.
            DashboardWidgetId.painNRS,
            DashboardWidgetId.gripStrength,
            DashboardWidgetId.waistCircumference,
            DashboardWidgetId.waistToHeight
        ])
    }

    @Test("reorder rewrites order indices")
    func reorderRewritesOrder() {
        let layout = DashboardWidgetLayout.default
        let next = layout.reordering(["pulse", "weight", "bp"])
        let pulse = next.widgets.first { $0.id == "pulse" }
        let weight = next.widgets.first { $0.id == "weight" }
        let bp = next.widgets.first { $0.id == "bp" }
        #expect(pulse?.order == 0)
        #expect(weight?.order == 1)
        #expect(bp?.order == 2)
        // Unmentioned rows preserved.
        #expect(next.widgets.count == layout.widgets.count)
    }

    @Test("widget id mapping is invertible for every supported MetricKind")
    func widgetIdMappingInvertible() {
        for kind in MetricKind.allCases {
            guard let id = DashboardWidgetId.id(forMetricKind: kind) else { continue }
            #expect(DashboardWidgetId.metricKind(forId: id) == kind, "Roundtrip failed for \(kind)")
        }
    }

    @Test("non-metric widget ids do not surface as MetricKind")
    func nonMetricWidgetIdsDoNotMap() {
        #expect(DashboardWidgetId.metricKind(forId: "medications") == nil)
        #expect(DashboardWidgetId.metricKind(forId: "achievements") == nil)
        #expect(DashboardWidgetId.metricKind(forId: "bpInTarget") == nil)
        // v0.5.2 F2: vo2Max became a MetricKind, removed from the non-metric
        // list. The remaining three are app-level surfaces, not chart metrics.
        #expect(DashboardWidgetId.metricKind(forId: "vo2Max") == .vo2Max)
        // Build 7 / item 7.3: `mood` GRADUATED to a first-class metric tile — it
        // now maps to `.mood` (the summary route emits a mood card, #51), so it
        // is deliberately no longer in the non-metric set above.
        #expect(DashboardWidgetId.metricKind(forId: "mood") == .mood)
        #expect(DashboardWidgetId.id(forMetricKind: .mood) == "mood")
    }
}
