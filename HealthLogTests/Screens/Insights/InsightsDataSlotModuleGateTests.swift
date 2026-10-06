import Foundation
@testable import HealthLog
import Testing

/// **Work order #115 · 0.1 — data slots no longer hang on `insights`.**
///
/// Server v1.39 narrowed the `insights` module to "AI analysis", and migration
/// 0343 switched it OFF for every account that had "Hide Coach" on. Build 279
/// gated the score rings, the signals, the rhythm events, the health status,
/// the breathing screening, the lab changes, the correlations and the ECG page
/// on that module, so those accounts lost every one of them the moment
/// production updated.
///
/// Each case below is the account after migration 0343 — `insights: false`,
/// everything else on — and asserts the slot is shown. The two slots whose data
/// belongs to a toggleable module (breathing → `sleep`, lab changes → `labs`)
/// additionally follow that module, exactly as their v1.39.0 routes do.
@Suite("Insights data slots — shown with modules.insights = false (server v1.39)")
@MainActor
struct InsightsDataSlotModuleGateTests {
    /// A "Hide Coach" account after migration 0343.
    private func hideCoachGate() -> ModuleGate {
        ModuleGate(modules: ["insights": false, "sleep": true, "labs": true, "coach": false])
    }

    // MARK: - One test per slot

    @Test("score rings (DEINE GESUNDHEITSWERTE) show with insights = false")
    func wellnessScores() {
        #expect(InsightsOverviewGate.isVisible(.wellnessScores, gate: hideCoachGate()))
    }

    @Test("signals of the day show with insights = false")
    func signals() {
        #expect(InsightsOverviewGate.isVisible(.signals, gate: hideCoachGate()))
    }

    @Test("rhythm events show with insights = false")
    func rhythmEvents() {
        #expect(InsightsOverviewGate.isVisible(.rhythmEvents, gate: hideCoachGate()))
    }

    @Test("health status shows with insights = false")
    func healthStatus() {
        #expect(InsightsOverviewGate.isVisible(.healthStatus, gate: hideCoachGate()))
    }

    @Test("breathing screening shows with insights = false")
    func breathing() {
        #expect(InsightsOverviewGate.isVisible(.breathing, gate: hideCoachGate()))
    }

    @Test("lab changes show with insights = false")
    func labsChanges() {
        #expect(InsightsOverviewGate.isVisible(.labsChanges, gate: hideCoachGate()))
    }

    @Test("correlations show with insights = false")
    func correlations() {
        #expect(InsightsOverviewGate.isVisible(.correlations, gate: hideCoachGate()))
    }

    @Test("ECG page keeps its pill with insights = false")
    func ecgPage() {
        #expect(InsightsSpecialPage.ecg.moduleKey == nil)
        #expect(InsightsSpecialPage.ecg.isModuleEnabled(in: hideCoachGate()))
    }

    // MARK: - Ownership, as the server routes gate it

    @Test("every data slot's owning module matches its v1.39.0 route")
    func owningModulesMatchServer() {
        let expected: [(InsightsOverviewDataSlot, ModuleKey?)] = [
            (.wellnessScores, nil), // derived/batch — per-metric ownership server-side
            (.signals, nil), // derived/batch
            (.rhythmEvents, nil), // rhythm-events — no module gate
            (.healthStatus, nil), // health-status — no module gate
            (.breathing, .sleep), // breathing-screening → requireModuleEnabled("sleep")
            (.labsChanges, .labs), // labs-changes → requireModuleEnabled("labs")
            (.correlations, nil) // correlations — channels filtered server-side
        ]
        #expect(expected.map(\.0) == InsightsOverviewDataSlot.allCases)
        for (slot, module) in expected {
            #expect(slot.owningModule == module, "\(slot)")
            #expect(slot.owningModule != .insights, "\(slot) must never hang on the AI module")
        }
    }

    @Test("breathing follows sleep, lab changes follow labs")
    func ownedSlotsFollowTheirModule() {
        let off = ModuleGate(modules: ["insights": true, "sleep": false, "labs": false])
        #expect(!InsightsOverviewGate.isVisible(.breathing, gate: off))
        #expect(!InsightsOverviewGate.isVisible(.labsChanges, gate: off))
        #expect(InsightsOverviewGate.isVisible(.rhythmEvents, gate: off))
        #expect(InsightsOverviewGate.isVisible(.healthStatus, gate: off))
    }

    @Test("no module map (older server / not loaded yet) fails open")
    func absentMapFailsOpen() {
        for slot in InsightsOverviewDataSlot.allCases {
            #expect(InsightsOverviewGate.isVisible(slot, gate: ModuleGate()))
            #expect(InsightsOverviewGate.isVisible(slot, gate: nil))
        }
    }

    // MARK: - Nothing else reads the AI module as a data gate

    /// The one remaining `insights` read in app code is the Tagesbriefing slot
    /// (AI-written text, kept as in 1.0.3 until the `ai` capability model lands).
    /// A second read anywhere — a new slot, the ECG sweep, a widget — is the
    /// 279 bug coming back.
    @Test("app code reads the insights module in exactly one place: the Tagesbriefing slot")
    func singleInsightsModuleRead() throws {
        let sources = try Self.appSources()
        var directReads: [String] = []
        var briefingGateCalls: [String] = []
        for (path, text) in sources {
            let code = Self.codeBody(of: text)
            if code.contains("isEnabled(.insights)") { directReads.append(path) }
            let calls = code.components(separatedBy: "InsightsOverviewGate.insightsModuleEnabled(").count - 1
            for _ in 0 ..< calls {
                briefingGateCalls.append(path)
            }
        }
        #expect(directReads == ["HealthLog/Screens/Insights/Sub/InsightsOverviewSlots.swift"], "\(directReads)")
        #expect(briefingGateCalls == ["HealthLog/Screens/Insights/Sub/InsightsOverviewSlots.swift"], "\(briefingGateCalls)")
        // …and that one call sits inside the Tagesbriefing slot.
        let slots = try #require(sources["HealthLog/Screens/Insights/Sub/InsightsOverviewSlots.swift"])
        let start = try #require(slots.range(of: "struct InsightsDailyBriefingSlot"))
        let rest = slots[start.upperBound...]
        let end = rest.range(of: "\nstruct ")?.lowerBound ?? rest.endIndex
        #expect(Self.codeBody(of: String(rest[..<end])).contains("InsightsOverviewGate.insightsModuleEnabled(appContainer)"))
    }

    // MARK: - Helpers

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Insights/
            .deletingLastPathComponent() // Screens/
            .deletingLastPathComponent() // HealthLogTests/
            .deletingLastPathComponent() // repo root
    }

    /// Every `.swift` file of the app, widget, watch and extension targets,
    /// keyed by its repo-relative path.
    private static func appSources() throws -> [String: String] {
        let targets = [
            "HealthLog", "HealthLogWidgets", "HealthLogWatch", "HealthLogWatchWidgets",
            "NotificationServiceExtension"
        ]
        let fm = FileManager.default
        var result: [String: String] = [:]
        for target in targets {
            let root = repoRoot.appendingPathComponent(target)
            guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                let relative = String(url.path.dropFirst(repoRoot.path.count + 1))
                result[relative] = try String(contentsOf: url, encoding: .utf8)
            }
        }
        #expect(result.count > 100, "the source walk found almost nothing — the guard would pass vacuously")
        return result
    }

    private static func codeBody(of source: String) -> String {
        source
            .components(separatedBy: "\n")
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !trimmed.hasPrefix("//") && !trimmed.hasPrefix("///")
            }
            .joined(separator: "\n")
    }
}
