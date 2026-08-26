import Foundation
@testable import HealthLog
import Testing

/// Phase 07 Wave 0 — one route per trigger, entered exactly once.
///
/// Foreground, manual, silent push, AppRefresh, Processing, post-authentication
/// activation, cold activation, and every observer must enter the same
/// orchestrator, once, under one lease. Today each call site reaches collectors
/// and importers directly, several triggers are entered by more than one call
/// site, and no trigger carries its budget to the work it starts.
@Suite("HealthKit sync trigger routing")
struct HealthSyncTriggerRoutingTests {
    @Test("every trigger carries an explicit, bounded budget")
    func everyTriggerHasABudget() {
        for trigger in HealthSyncTrigger.allCases {
            let budget = HealthSyncBudget.required(for: trigger)
            #expect(budget.maxPagesPerType >= 0)
        }

        #expect(HealthSyncBudget.required(for: .appRefresh).incrementalOnly)
        #expect(HealthSyncBudget.required(for: .silentPush).incrementalOnly)
        #expect(!HealthSyncBudget.required(for: .appRefresh).allowsFirstHistoryImport)
        #expect(!HealthSyncBudget.required(for: .silentPush).allowsFirstHistoryImport)

        let processing = HealthSyncBudget.required(for: .processing)
        #expect(!processing.incrementalOnly)
        #expect(processing.allowsFirstHistoryImport)
        #expect(processing.maxPagesPerType > HealthSyncBudget.required(for: .appRefresh).maxPagesPerType)

        #expect(HealthSyncBudget.required(for: .accountTeardown).maxPagesPerType == 0)
    }

    @Test("every trigger is represented in the frozen inventory")
    func everyTriggerIsInventoried() {
        for trigger in HealthSyncTrigger.allCases {
            let rows = HealthSyncTriggerInventory.rows.filter { $0.trigger == trigger }
            #expect(!rows.isEmpty, "no inventoried call site for \(trigger.rawValue)")
        }
    }

    @Test("every inventoried route is owned by a Phase-07 plan and a suite")
    func everyRouteHasAnOwnerAndTest() {
        for row in HealthSyncTriggerInventory.rows {
            #expect(row.ownerPlan.count == 5, "\(row.id) owner is not a plan id")
            #expect(row.testIdentifier.hasPrefix("HealthLogTests/"), "\(row.id) test identifier is not a suite path")
        }
    }

    // MARK: - RED

    /// Every inventoried call site must enter orchestration exactly once: none
    /// unrouted, none entering twice for the same trigger, and no production
    /// entry point still deciding the work itself.
    @Test("every inventoried route enters exactly once")
    func everyInventoriedRouteEntersExactlyOnce() throws {
        var violations: [String] = []

        let unrouted = HealthSyncTriggerInventory.rows.filter { $0.routing != .orchestrated }
        for row in unrouted {
            violations.append("\(row.id) reaches HealthKit without the orchestrator")
        }

        for trigger in HealthSyncTrigger.allCases {
            let entries = HealthSyncTriggerInventory.rows
                .filter { $0.trigger == trigger && $0.routing != .orchestrated }
            if entries.count > 1 {
                violations.append("\(trigger.rawValue) is entered by \(entries.count) direct call sites")
            }
        }

        let entryPoints = [
            "HealthLog/App/RootView.swift",
            "HealthLog/Stores/HKReadinessStore.swift",
            "HealthLog/Services/NotificationService+Registration.swift",
            "HealthLog/Services/BackgroundSyncCoordinator.swift"
        ]
        for path in entryPoints {
            let contents = try Self.source(path)
            if !contents.contains("HealthSyncTrigger") {
                violations.append("\(path) does not name the trigger it starts work for")
            }
        }

        #expect(violations.isEmpty, "EXPECTED_RED: direct trigger was missing duplicated or bypassed orchestration")
    }

    // MARK: - Source access

    private static func source(_ relativePath: String, file: String = #filePath) throws -> String {
        let root = URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
