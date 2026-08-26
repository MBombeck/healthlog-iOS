import Foundation
@testable import HealthLog
import Testing

/// v0.5.1-A B1 — on-device → server-shape mapping.
///
/// v0.9.0 dead-code cleanup: the `curatedDigest` cluster was deleted (the
/// live Statistik-Mode floor is `StatistikModeBriefingService`, covered by
/// `StatistikModeBriefingServiceTests`). The only surviving live surface in
/// this suite is `mapToServerShape`, kept here.
@Suite("OnDeviceBriefingHero — server-shape mapping")
@MainActor
struct DailyBriefingHeroOnDeviceV051ATests {
    @Test("mapToServerShape no longer leaks on_device_* sourceMetric")
    func mapDoesNotLeakSyntheticIDs() {
        let briefing = OnDeviceBriefing(
            summary: "Calm digest.",
            keyFindings: ["A", "B"],
            actionableNudges: [],
            confidence: 0.8,
            safetyApplied: true
        )
        let mapped = OnDeviceBriefingHero.mapToServerShape(briefing)
        for finding in mapped.keyFindings {
            #expect(finding.sourceMetric.isEmpty)
        }
    }
}
