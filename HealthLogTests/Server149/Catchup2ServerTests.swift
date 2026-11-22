import Foundation
@testable import HealthLog
import Testing

// #191, server answers of 21.11. 19:06 UTC: both ends of a 422 bound, the
// notable value's metric page and the range unit as sent. The dose offset
// lives in `SymptomDoseOffsetTests`.

// MARK: - Both ends of a refused field

@Suite("1.49 a refused field names both ends when the server sends them")
struct Catchup2ValidationBoundsTests {
    private static func body(_ issues: String) -> Data {
        Data(#"{"data":null,"error":"Validation failed","details":{"issues":[\#(issues)]}}"#.utf8)
    }

    private static func number(_ value: Double) -> String {
        HLValueFormat.number(value, fractionDigits: 0 ... 2)
    }

    @Test("minimum and maximum with their own flags read as one range")
    func bothEnds() throws {
        let bounds = try #require(APIValidationBounds.from(body: Self.body(
            #"{"path":"amount","code":"too_big","minimum":0,"maximum":5000,"inclusive":true,"#
                + #""minimumInclusive":true,"maximumInclusive":true,"origin":"number"}"#
        )))
        #expect(bounds.minimum == .init(value: 0, inclusive: true))
        #expect(bounds.maximum == .init(value: 5000, inclusive: true))
        #expect(bounds.rangeText == String(localized: "error.bounds.between \(Self.number(0)) \(Self.number(5000))"))
    }

    @Test("each end keeps its own flag, not the broken bound's")
    func ownFlags() throws {
        let bounds = try #require(APIValidationBounds.from(body: Self.body(
            #"{"path":"amount","code":"too_small","minimum":0,"maximum":5000,"inclusive":false,"#
                + #""minimumInclusive":false,"maximumInclusive":true,"origin":"number"}"#
        )))
        #expect(bounds.minimum == .init(value: 0, inclusive: false))
        #expect(bounds.maximum == .init(value: 5000, inclusive: true))
    }

    @Test("without the two flags the single bound reads as before")
    func singleBound() throws {
        let bounds = try #require(APIValidationBounds.from(body: Self.body(
            #"{"path":"amount","code":"too_big","maximum":5000,"inclusive":false,"origin":"number"}"#
        )))
        #expect(bounds.minimum == nil)
        #expect(bounds.maximum == .init(value: 5000, inclusive: false))
        #expect(bounds.rangeText == String(localized: "error.bounds.below \(Self.number(5000))"))
    }
}

// MARK: - The notable value's metric page

#if canImport(UserNotifications) && canImport(UIKit)
    @Suite("1.49 a notable value opens its metric's page")
    @MainActor
    struct Catchup2AnomalyTargetTests {
        private func payload(url: String?, metric: String? = nil) -> APNsPayload {
            APNsPayload(title: "t", body: "b", eventType: "MEASUREMENT_ANOMALY", metricType: nil, deepLink: nil, url: url, metric: metric)
        }

        @Test("/insights/<slug> opens that page; a slug off the allowlist opens Insights")
        func pushPath() {
            #expect(DeepLinkRoute.fromPushPath("/insights/resting-pulse") == .insights(metric: "resting-pulse"))
            #expect(DeepLinkRoute.fromPushPath("/insights/Resting_Pulse") == .insights(metric: nil))
            #expect(DeepLinkRoute.fromPushPath("/insights") == .insights(metric: nil))
            #expect(NotificationService.bodyTapTarget(for: payload(url: "/insights/resting-pulse"))
                == .route(.insights(metric: "resting-pulse")))
        }

        @Test("a sealed envelope's d.metric names the page; an unknown type opens Insights")
        func relayMetric() {
            #expect(NotificationService.bodyTapTarget(for: payload(url: nil, metric: "RESTING_HEART_RATE"))
                == .route(.insights(metric: InsightsLayoutTileId.restingPulse)))
            #expect(NotificationService.bodyTapTarget(for: payload(url: nil, metric: "NOT_A_TYPE"))
                == .route(.insights(metric: nil)))
            #expect(NotificationService.bodyTapTarget(for: payload(url: nil)) == .route(.insights(metric: nil)))
        }

        @Test("the rebuilt relay userInfo carries metric to the tap")
        func parsesMetric() throws {
            let parsed = try #require(APNsPayload.parse(userInfo: ["eventType": "MEASUREMENT_ANOMALY", "metric": "RESTING_HEART_RATE"]))
            #expect(parsed.metric == "RESTING_HEART_RATE")
            #expect(APNsPayload.parse(userInfo: ["eventType": "X", "metric": ""])?.metric == nil)
        }
    }
#endif

// MARK: - The range unit as sent

@Suite("1.49 the range delta carries the server's unit")
struct Catchup2RangeUnitTests {
    @Test("the change keeps the unit the server sent; an older answer has none")
    func changeUnit() throws {
        let new = AnalyticsRangeTrend(range: "30d", windowDays: 30, delta: -0.4, deltaPct: -0.07, trend: .down, unit: "mmol/L")
        let change = try #require(ChartDetailStore.rangeChange(series: nil, rangeTrend: new))
        #expect(change.unit == "mmol/L")
        #expect(change.inAccountUnit)
        let old = AnalyticsRangeTrend(range: "30d", windowDays: 30, delta: -0.4, deltaPct: -0.07, trend: .down)
        #expect(ChartDetailStore.rangeChange(series: nil, rangeTrend: old)?.unit == nil)
    }
}
