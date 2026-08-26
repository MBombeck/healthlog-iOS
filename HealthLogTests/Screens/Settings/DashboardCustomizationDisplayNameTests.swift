import Foundation
@testable import HealthLog
import Testing

/// v0.14.x AUDIT-HOME M8 / HOME-12 — the dashboard customisation list must
/// never render a raw server widget id to the user. A server that adds a new
/// catalogue id (or re-emits a mapped-but-non-metric one) used to fall through
/// `displayName(for:)`'s `default: return id` and print the literal id string
/// in both languages. The fix routes the fallback through a neutral localized
/// label. These pin the contract on the pure `nonisolated static` resolver.
@Suite("DashboardCustomizationScreen — widget displayName fallback (HOME-12)")
struct DashboardCustomizationDisplayNameTests {
    /// The raw fallback string a regression would re-introduce.
    private let rawFallbackLeak = "recentWorkouts"

    @Test("Unknown server widget id falls back to a localized label, never the raw id")
    func unknownIdFallsBack() {
        let unknown = "someBrandNewServerWidgetThatIOSDoesNotKnow"
        let resolved = DashboardCustomizationScreen.displayName(for: unknown)
        #expect(resolved != unknown, "Unknown widget id must not render its raw id, got \(resolved)")
        #expect(resolved == String(localized: "home.widget.unknown.title"))
    }

    @Test("recentWorkouts (mapped-but-non-metric) never renders its raw id")
    func recentWorkoutsNeverRaw() {
        let resolved = DashboardCustomizationScreen.displayName(for: DashboardWidgetId.recentWorkouts)
        #expect(
            resolved != rawFallbackLeak,
            "recentWorkouts must not render its raw id, got \(resolved)"
        )
        #expect(resolved == String(localized: "home.widget.unknown.title"))
    }

    @Test("Mapped metric ids still resolve to their descriptor title")
    func mappedMetricResolvesTitle() {
        let resolved = DashboardCustomizationScreen.displayName(for: DashboardWidgetId.weight)
        #expect(resolved == String(localized: MetricKind.weight.descriptor.title))
        #expect(resolved != DashboardWidgetId.weight)
    }

    @Test("Non-metric but known ids keep their explicit localized label")
    func knownNonMetricResolves() {
        #expect(
            DashboardCustomizationScreen.displayName(for: DashboardWidgetId.medications)
                == String(localized: "Medications")
        )
        #expect(
            DashboardCustomizationScreen.displayName(for: DashboardWidgetId.mood)
                == String(localized: "Mood")
        )
    }
}
