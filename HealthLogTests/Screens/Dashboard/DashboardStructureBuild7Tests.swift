import Foundation
@testable import HealthLog
import Testing

// Build 7 — Dashboard-Struktur (items 7.3 + 7.5) + operator-feedback b235.
//
// 7.3 — mood graduated to a first-class dashboard metric tile and the `bmi`
//       summary token now decodes; this suite locks the render configuration
//       (descriptor / unit / widget-id round-trip / default layout) so a future
//       change can't silently un-render either tile.
// 7.5 — the four v1.25 clinical widget ids (pain / grip / waist / waist-to-
//       height) must map, surface, and SURVIVE a layout-save round-trip. Server
//       #54 (v1.31.0) made the PUT validate against the FULL widget-id catalogue
//       so it retains them; this is the iOS-side client contract for that.
// b235 — a dashboard partial failure must be reported by EITHER the top banner
//        OR the inline metrics error card, never both.

// `@MainActor`: `DashboardStore` is `@MainActor @Observable`, so its
// `kindSupportsSeries` static is MainActor-isolated (HANDOVER §4).
@Suite("Build 7.3 — mood dashboard tile render config")
@MainActor
struct MoodTileRenderConfigTests {
    @Test("mood is a first-class MetricKind with a real descriptor (no fallback)")
    func moodDescriptorIsConcrete() {
        let descriptor = MetricKind.mood.descriptor
        #expect(descriptor.kind == .mood)
        #expect(!descriptor.sfSymbol.isEmpty)
        #expect(descriptor.sfSymbol != "questionmark.circle", "mood fell through to the fallback descriptor")
        #expect(!String(localized: descriptor.title).isEmpty)
        #expect(descriptor.renderHint == .scalar)
        #expect(descriptor.trendPolarity == .higherIsBetter)
    }

    @Test("mood is present in the descriptor catalog (exhaustiveness)")
    func moodInCatalog() {
        #expect(MetricKindDescriptor.catalog[.mood] != nil)
    }

    @Test("mood decodes from its raw value and is unitless")
    func moodRawValueAndUnit() {
        #expect(MetricKind(rawValue: "mood") == .mood)
        #expect(MetricKind.mood.rawValue == "mood")
        #expect(MetricKind.mood.unit.isEmpty)
    }

    @Test("mood widget id round-trips through both maps")
    func moodWidgetIdRoundTrips() {
        #expect(DashboardWidgetId.metricKind(forId: DashboardWidgetId.mood) == .mood)
        #expect(DashboardWidgetId.id(forMetricKind: .mood) == DashboardWidgetId.mood)
    }

    @Test("mood ships tile-visible in the iOS default layout")
    func moodVisibleInDefaultLayout() {
        let moodRow = DashboardWidgetLayout.default.widgets.first { $0.id == DashboardWidgetId.mood }
        #expect(moodRow?.effectiveTileVisible == true)
    }

    @Test("mood has no measurement-series backing (renders from the summary snapshot)")
    func moodHasNoSeries() {
        #expect(DashboardStore.kindSupportsSeries(.mood) == false)
        #expect(ChartDetailStore.kindSupportsSeries(.mood) == false)
    }

    @Test("mood is never manually written (no create-DTO arm)")
    func moodIsNotManuallyWritable() {
        let measurement = Measurement(
            id: "m", kind: .mood,
            recordedAt: Date(timeIntervalSince1970: 0),
            value: .scalar(4), source: .manual
        )
        #expect(measurement.toCreateDTOs().isEmpty)
    }
}

@Suite("Build 7.5 — clinical widget ids survive a layout save")
struct ClinicalWidgetIdLayoutSaveTests {
    private static let clinicalIds = [
        DashboardWidgetId.painNRS,
        DashboardWidgetId.gripStrength,
        DashboardWidgetId.waistCircumference,
        DashboardWidgetId.waistToHeight
    ]

    @Test("each clinical widget id maps to its MetricKind and back")
    func clinicalIdsMapBothWays() {
        let expected: [(String, MetricKind)] = [
            (DashboardWidgetId.painNRS, .painNRS),
            (DashboardWidgetId.gripStrength, .gripStrength),
            (DashboardWidgetId.waistCircumference, .waistCircumference),
            (DashboardWidgetId.waistToHeight, .waistToHeight)
        ]
        for (id, kind) in expected {
            #expect(DashboardWidgetId.metricKind(forId: id) == kind, "\(id) did not map to \(kind)")
            #expect(DashboardWidgetId.id(forMetricKind: kind) == id, "\(kind) did not map back to \(id)")
        }
    }

    @Test("each clinical widget id resolves a human display name (never a raw id leak)")
    func clinicalIdsHaveDisplayNames() {
        for id in Self.clinicalIds {
            let name = DashboardCustomizationScreen.displayName(for: id)
            #expect(!name.isEmpty)
            #expect(name != id, "\(id) leaked its raw id as the display name")
        }
    }

    @Test("the four clinical ids ship in the default layout, tile-visible")
    func clinicalIdsInDefaultLayout() {
        for id in Self.clinicalIds {
            let row = DashboardWidgetLayout.default.widgets.first { $0.id == id }
            #expect(row != nil, "\(id) missing from the default layout")
            #expect(row?.effectiveTileVisible == true, "\(id) should be tile-visible by default")
        }
    }

    /// Layout-save integration contract: the PUT body is the ENCODED layout. A
    /// layout carrying the four clinical widget ids must round-trip cleanly
    /// (encode → decode) so the iOS save actually SENDS them — server #54 then
    /// retains them (the PUT validates against the full catalogue). Pre-#54 they
    /// were dropped through the unknown-id filter, silently losing the user's
    /// placement of those four tiles on every save.
    @Test("a layout with the four clinical ids round-trips through encode/decode")
    func clinicalIdsSurviveEncodeDecode() throws {
        let widgets = Self.clinicalIds.enumerated().map { index, id in
            DashboardWidgetConfig(id: id, visible: false, tileVisible: true, order: index)
        }
        let layout = DashboardWidgetLayout(widgets: widgets)

        let data = try JSONEncoder().encode(layout)
        let decoded = try JSONDecoder().decode(DashboardWidgetLayout.self, from: data)

        for id in Self.clinicalIds {
            let row = decoded.widgets.first { $0.id == id }
            #expect(row != nil, "\(id) lost across the layout PUT round-trip")
            #expect(row?.effectiveTileVisible == true, "\(id) lost its tile visibility across the round-trip")
        }
        #expect(decoded.widgets.count == Self.clinicalIds.count)
    }
}

@Suite("b235 — dashboard error is never reported twice")
struct DashboardTopBannerSuppressionTests {
    @Test("a partial failure (no summary, error, not loading) suppresses the top banner")
    func partialFailureSuppressesBanner() {
        // The inline metrics error card (#67) is showing → the banner must stay
        // silent so the outage isn't reported twice.
        #expect(
            DashboardMetricsSectionState.suppressesTopBanner(
                hasSummary: false, hasError: true, isLoading: false
            ) == true
        )
        // And this is exactly the inline-card state.
        #expect(
            DashboardMetricsSectionState.resolve(
                hasSummary: false, hasError: true, isLoading: false
            ) == .error
        )
    }

    @Test("an error while a cached summary still renders keeps the banner (only surface)")
    func errorWithCachedSummaryKeepsBanner() {
        // Tiles still paint from the cached summary; the inline error card is NOT
        // shown, so the banner remains the sole error surface (unchanged).
        #expect(
            DashboardMetricsSectionState.suppressesTopBanner(
                hasSummary: true, hasError: true, isLoading: false
            ) == false
        )
    }

    @Test("an in-flight retry (no summary, error, loading) does NOT suppress — skeleton, not inline card")
    func inFlightRetryKeepsBanner() {
        // During a retry the section shows the skeleton, not the inline error
        // card, so the banner is allowed (matches the inline card exactly).
        #expect(
            DashboardMetricsSectionState.suppressesTopBanner(
                hasSummary: false, hasError: true, isLoading: true
            ) == false
        )
    }

    @Test("a plain cold load with no error does not suppress")
    func coldLoadKeepsBanner() {
        #expect(
            DashboardMetricsSectionState.suppressesTopBanner(
                hasSummary: false, hasError: false, isLoading: true
            ) == false
        )
    }
}
