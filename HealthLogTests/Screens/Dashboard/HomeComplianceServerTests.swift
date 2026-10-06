import Foundation
@testable import HealthLog
import Testing

/// #115 · 1.3 — the Home ring and the compliance widget show only what the
/// server computed.
@Suite("Home ring + widget compliance — server values (#115 1.3)")
@MainActor
struct HomeComplianceServerTests {
    // MARK: - Home ring refresh policy

    @Test("the first load (not loaded → loaded) never triggers a summary refresh")
    func launchAddsNoRequest() {
        #expect(!DashboardIntakeSignature.shouldRefreshSummary(
            from: .init(loaded: false, resolved: 0),
            to: .init(loaded: true, resolved: 2)
        ))
    }

    @Test("a dose marked on an already-loaded list re-reads the server summary")
    func markReReadsServer() {
        #expect(DashboardIntakeSignature.shouldRefreshSummary(
            from: .init(loaded: true, resolved: 1),
            to: .init(loaded: true, resolved: 2)
        ))
        #expect(!DashboardIntakeSignature.shouldRefreshSummary(
            from: .init(loaded: true, resolved: 2),
            to: .init(loaded: true, resolved: 2)
        ))
    }

    // MARK: - Widget ring

    private static func snapshot(rate: Int, applicable: Bool = true) -> MedicationsStore.ComplianceCardSnapshot {
        MedicationsStore.ComplianceCardSnapshot(
            rate7: rate, rate30: rate,
            displayShortDays: 7, displayShortRate: rate,
            displayLongDays: 30, displayLongRate: rate,
            applicable: applicable
        )
    }

    @Test("several medications: no unweighted mean of per-medication rates")
    func noUnweightedMean() {
        // A twice-daily tablet at 100 % and a weekly injection at 0 %: the old
        // aggregate painted 50 %, a figure no server computes.
        let percent = AppContainer.serverCompliancePercent(
            activeIDs: ["tablet", "injection"],
            snapshots: ["tablet": Self.snapshot(rate: 100), "injection": Self.snapshot(rate: 0)]
        )
        #expect(percent == nil)
    }

    @Test("one applicable medication: its server rate is the account rate")
    func singleMedication() {
        #expect(AppContainer.serverCompliancePercent(
            activeIDs: ["tablet"],
            snapshots: ["tablet": Self.snapshot(rate: 86)]
        ) == 86)
    }

    @Test("NO_LOCAL_SCHEDULE placeholders never count and never paint 0 %")
    func notApplicableExcluded() {
        #expect(AppContainer.serverCompliancePercent(
            activeIDs: ["tablet", "external"],
            snapshots: ["tablet": Self.snapshot(rate: 86), "external": Self.snapshot(rate: 0, applicable: false)]
        ) == 86)
        #expect(Self.snapshot(rate: 0, applicable: false).displayRows.isEmpty)
    }
}
