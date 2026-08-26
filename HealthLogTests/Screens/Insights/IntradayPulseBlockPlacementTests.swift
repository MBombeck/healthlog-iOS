import Foundation
@testable import HealthLog
import Testing

/// P7 — where the intraday day curve is allowed to exist.
///
/// The block reads a server-only route, so its placement gate is the thing that
/// keeps every OTHER metric page from firing that read and keeps the block out
/// of standalone / no-server entirely (no round-trip, no empty shell). Pure
/// logic, pinned here so a future refactor of `InsightsMetricScreen+Sections`
/// cannot silently widen it.
@Suite("IntradayPulseBlock — placement gate (pulse-only + cloud-gated)")
struct IntradayPulseBlockPlacementTests {
    @Test("the block exists on the pulse page when a cloud surface is available")
    func availableOnPulse() {
        #expect(IntradayPulseBlock.isAvailable(for: .pulse, canShowCloudInsights: true))
    }

    @Test("no other metric page ever mounts the block")
    func suppressedOnEveryOtherKind() {
        for kind in MetricKind.allCases where kind != .pulse {
            #expect(
                !IntradayPulseBlock.isAvailable(for: kind, canShowCloudInsights: true),
                "\(kind.rawValue) must not fire the intraday read"
            )
        }
    }

    @Test("standalone / no-server hides the block even on the pulse page")
    func suppressedWithoutCloud() {
        #expect(!IntradayPulseBlock.isAvailable(for: .pulse, canShowCloudInsights: false))
    }

    @Test("the intraday copy keys resolve (no raw key leaks into the UI)")
    func copyKeysResolve() {
        // A missing catalog entry resolves to the key itself — assert the
        // resolved string differs, in whichever locale the test host runs.
        for key in [
            "insights.intraday.title",
            "insights.intraday.caption",
            "insights.intraday.baseline",
            "insights.intraday.hourlyNote",
            "insights.intraday.empty",
            "insights.intraday.today",
            "insights.intraday.previousDay",
            "insights.intraday.nextDay",
            "insights.intraday.loadFailed",
            "insights.intraday.tension.morning",
            "insights.intraday.tension.afternoon",
            "insights.intraday.tension.evening",
            "insights.intraday.tension.night"
        ] {
            let resolved = String(localized: String.LocalizationValue(key))
            #expect(resolved != key, "missing localization for \(key)")
        }
    }
}
