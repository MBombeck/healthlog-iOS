import Foundation
@testable import HealthLog
import Testing

/// Phase 07 Wave 0 — the executable definition of "sync everything".
///
/// A manual or foreground sweep must reach every enabled importer, a short
/// background wake must stay incremental, an observer must touch only the
/// source it was signalled for, and cold activation must install the chosen
/// backfill cutoff before the first query. Anything disabled, unsupported, or
/// postponed is named, never silently omitted.
@Suite("Complete HealthKit sync composition")
struct CompleteHealthSyncCompositionTests {
    // MARK: - Inventories

    @Test("the sample registry is exactly the thirty-five collected identifiers")
    func sampleRegistryIsExact() {
        #expect(HealthLogSampleTypeRegistry.knownIdentifiers.count == 35)
        #expect(HealthLogSampleTypeRegistry.contains("HKQuantityTypeIdentifierHeartRate"))
        #expect(HealthLogSampleTypeRegistry.contains("HKQuantityTypeIdentifierTimeInDaylight"))
        #expect(!HealthLogSampleTypeRegistry.contains("HKQuantityTypeIdentifierBloodAlcoholContent"))
    }

    @Test("every non-sample importer is a distinct named capability")
    func nonSampleImportersAreNamed() {
        let nonSample = HealthSyncCapability.allCases.filter { !$0.isSampleCollection }
        #expect(nonSample.count == 10)
        #expect(Set(nonSample.map(\.source)).count == nonSample.count)
        #expect(Set(HealthSyncCapability.allCases.map(\.rawValue)).count == HealthSyncCapability.allCases.count)

        let optIn = HealthSyncCapability.allCases.filter(\.requiresExplicitOptIn).map(\.rawValue).sorted()
        #expect(optIn == [
            "appleMedicationImport",
            "cycleImport",
            "ecgUpload",
            "moodStateOfMindImport",
            "nutrientDailyTotals"
        ])
    }

    @Test("background scheduling makes no fixed-period claim")
    func schedulingClaimIsHonest() {
        #expect(!HealthSyncSchedulingTruth.guaranteesFixedPeriod)
        let claim = HealthSyncSchedulingTruth.claim.lowercased()
        for forbidden in ["every ", "minute", "hour", "alle ", "stünd"] {
            #expect(!claim.contains(forbidden), "the scheduling claim promises a cadence: \(forbidden)")
        }
    }

    // MARK: - Trigger inventory integrity

    @Test("every inventoried trigger still names real production code")
    func inventoryRowsNameRealCode() throws {
        for row in HealthSyncTriggerInventory.rows {
            let contents = try Self.source(row.file)
            #expect(contents.contains(row.symbol), "\(row.id) no longer resolves: \(row.file) :: \(row.symbol)")
        }
    }

    @Test("the markdown inventory and the executable twin agree")
    func markdownAndTableAgree() throws {
        let markdown = try Self.source(
            ".planning/phases/07-healthkit-durability-and-complete-sync/07-TRIGGER-OWNERSHIP.md"
        )
        let documented = markdown
            .split(separator: "\n")
            .filter { $0.hasPrefix("| T-") }
            .map { line in
                line
                    .split(separator: "|", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "`", with: "") }
            }

        #expect(documented.count == HealthSyncTriggerInventory.rows.count)
        for columns in documented {
            guard columns.count >= 8 else {
                Issue.record("inventory row is malformed: \(columns)")
                continue
            }
            let row = HealthSyncTriggerInventory.row(columns[1])
            #expect(row?.file == columns[2], "\(columns[1]) file drifted")
            #expect(row?.symbol == columns[3], "\(columns[1]) symbol drifted")
            #expect(row?.trigger.rawValue == columns[4], "\(columns[1]) trigger drifted")
            #expect(row?.ownerPlan == columns[5], "\(columns[1]) owner drifted")
            #expect(row?.routing.rawValue == columns[6], "\(columns[1]) routing drifted")
            #expect(row?.testIdentifier.hasSuffix(columns[7]) == true, "\(columns[1]) test identifier drifted")
        }
    }

    @Test("no inventory row is unassigned")
    func inventoryIsFullyOwned() {
        for row in HealthSyncTriggerInventory.rows {
            #expect(!row.ownerPlan.isEmpty)
            #expect(row.ownerPlan.hasPrefix("07-"))
            #expect(!row.testIdentifier.isEmpty)
        }
        #expect(Set(HealthSyncTriggerInventory.rows.map(\.id)).count == HealthSyncTriggerInventory.rows.count)
    }

    // MARK: - Composition truth

    /// Phase 07 / plan 07-07 — the check that would have caught the phase's
    /// largest defect four waves earlier.
    ///
    /// Every Phase-07 admission resolves against
    /// `AuthenticatedSessionLeaseRegistry`, and nothing in production ever
    /// activates it: `AuthStore.activateAuthenticatedSession(ownerID:)` and the
    /// container's boundary hooks are called only from tests, so
    /// `capture(ownerID:)` returns `nil` on a device and every admission-gated
    /// sweep refuses while every toggle reads "on". The unit suite could not see
    /// it because each test activates the registry by hand.
    ///
    /// So the fact is a constant, and this test binds the constant to the call
    /// graph in both directions: adding a production activation without flipping
    /// the constant fails here, and flipping the constant without adding one
    /// fails here too. It is deliberately not an `EXPECTED_RED` — it passes
    /// today, stating an uncomfortable truth, and Plan 07-09 makes it pass again
    /// by making the truth a different one.
    @Test("the session-registry activation constant matches the production call graph")
    func sessionRegistryActivationConstantMatchesProduction() throws {
        let callSites = try Self.authenticatedSessionActivationCallSites()
        #expect(
            HealthSyncCompositionPlan.installedActivatesSessionRegistry == !callSites.isEmpty,
            """
            installedActivatesSessionRegistry is \
            \(HealthSyncCompositionPlan.installedActivatesSessionRegistry) \
            but production activation call sites are \(callSites.sorted())
            """
        )
        #expect(HealthSyncCompositionPlan.requiredActivatesSessionRegistry)
    }

    /// Non-comment production lines that would activate the shared registry.
    ///
    /// Comments are stripped on purpose: the constant's own documentation names
    /// both symbols, and a doc comment is not a call — the trap Plan 07-06 hit
    /// when two RED clauses passed on a class doc comment.
    private static func authenticatedSessionActivationCallSites() throws -> Set<String> {
        var found: Set<String> = []
        for file in try productionSwiftFiles() {
            let relative = file.path.replacingOccurrences(of: repositoryRoot().path + "/", with: "")
            let contents = try String(contentsOf: file, encoding: .utf8)
            for rawLine in contents.split(separator: "\n") {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                guard !line.hasPrefix("//"), !line.hasPrefix("*"), !line.hasPrefix("/*") else { continue }
                if line.contains("activateAuthenticatedSession(ownerID:"), !line.hasPrefix("func ") {
                    found.insert("\(relative) :: activateAuthenticatedSession")
                }
                if line.contains("authenticatedSessionBoundaryHooks"),
                   !relative.hasSuffix("AppContainer+LogoutHooks.swift")
                {
                    found.insert("\(relative) :: authenticatedSessionBoundaryHooks")
                }
            }
        }
        return found
    }

    private static func productionSwiftFiles() throws -> [URL] {
        let root = repositoryRoot().appendingPathComponent("HealthLog")
        guard let walker = FileManager.default.enumerator(atPath: root.path) else { return [] }
        return walker
            .compactMap { $0 as? String }
            .filter { $0.hasSuffix(".swift") }
            .map { root.appendingPathComponent($0) }
    }

    private static func repositoryRoot(file: String = #filePath) -> URL {
        URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    // MARK: - RED

    /// Manual, foreground, processing, and post-authentication passes must reach
    /// every capability; short wakes must reach the incremental set; cold
    /// activation must install the cutoff first; and every inventoried direct
    /// trigger must enter the orchestrator.
    @Test("the exact registry and every direct trigger are complete")
    func exactRegistryAndEveryDirectTriggerAreComplete() throws {
        var violations: [String] = []

        for trigger in HealthSyncTrigger.allCases {
            let required = HealthSyncCompositionPlan.required(for: trigger)
            let installed = HealthSyncCompositionPlan.installed(for: trigger)
            let missing = required.subtracting(installed)
            if !missing.isEmpty {
                violations.append("\(trigger.rawValue) omits \(missing.count) capability(ies)")
            }
        }

        if HealthSyncCompositionPlan.installedInstallsCutoffBeforeFirstQuery
            != HealthSyncCompositionPlan.requiredInstallsCutoffBeforeFirstQuery
        {
            violations.append("cold activation queries before the chosen cutoff is installed")
        }

        let unrouted = HealthSyncTriggerInventory.rows.filter { $0.routing != .orchestrated }
        if !unrouted.isEmpty {
            violations.append("\(unrouted.count) of \(HealthSyncTriggerInventory.rows.count) triggers are unrouted")
        }

        let coordinator = try Self.source("HealthLog/Services/BackgroundSyncCoordinator.swift")
        if !coordinator.contains("HealthSyncCapability") {
            violations.append("the background coordinator reports no named capability results")
        }

        #expect(violations.isEmpty, "EXPECTED_RED: registry or direct trigger coverage was incomplete")
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
