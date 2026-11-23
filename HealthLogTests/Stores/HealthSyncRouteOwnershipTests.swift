// What each HealthKit sync trigger is allowed to plan: no pull trigger installs
// more capabilities than its plan requires, the two short wakes stay
// incremental inside the seconds iOS grants them, and no entry point reaches
// a sync capability beside the orchestrated pass.

#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing

    @Suite("HealthKit sync route ownership")
    struct HealthSyncRouteOwnershipTests {
        /// Every capability set a trigger reaches must be exactly what its plan
        /// requires. Wave 0's RED asserts `required ⊆ installed`; this asserts the
        /// other direction for the seven pull triggers, so a composition cannot
        /// quietly do *more* than its budget allows either.
        @Test("no pull trigger installs more than its plan requires")
        func installedNeverExceedsRequired() {
            for trigger in HealthSyncTrigger.allCases {
                let installed = HealthSyncCompositionPlan.installed(for: trigger)
                switch trigger {
                case .observer, .accountTeardown:
                    #expect(installed.isEmpty, "\(trigger.rawValue) resolves per signalled source, never a fan-out")
                case .appRefresh, .silentPush:
                    // A short wake reaches every capability *by name* and plans
                    // only the incremental set; the rest come back `deferred`.
                    #expect(installed == HealthSyncCompositionPlan.completeSet)
                    #expect(
                        HealthSyncCompositionPlan.required(for: trigger)
                            == HealthSyncCompositionPlan.incrementalSet
                    )
                case .coldActivation, .postAuthentication, .foreground, .manual, .processing:
                    #expect(installed == HealthSyncCompositionPlan.completeSet)
                }
            }
        }

        /// The silent push and the AppRefresh wake must stay incremental: one page
        /// per type, and no first history walk inside a wake iOS bounds at seconds.
        @Test("the two short wakes stay incremental")
        func shortWakesStayIncremental() {
            for trigger in [HealthSyncTrigger.silentPush, .appRefresh] {
                let budget = HealthSyncBudget.required(for: trigger)
                #expect(budget.maxPagesPerType == 1)
                #expect(budget.incrementalOnly)
                #expect(!budget.allowsFirstHistoryImport)
            }
        }

        /// A direct capability call outside the orchestrator runs beside the
        /// orchestrated pass and syncs twice; every remaining caller is reviewed here.
        @Test("sync capabilities are entered only by the orchestrator and reviewed user actions")
        func noDirectEntryBesideTheOrchestrator() throws {
            let appRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent() // Stores
                .deletingLastPathComponent() // HealthLogTests
                .deletingLastPathComponent() // <repo>
                .appendingPathComponent("HealthLog")
            let needles = [
                "triggerDailyStatsSync(",
                "triggerHRBucketSync(",
                "triggerNutrientSync(",
                "triggerEcgSync(",
                "SpeziCollectionTrigger.run("
            ]
            var scanned = 0
            var callers: [String: [String]] = [:]
            let files = try #require(FileManager.default.enumerator(at: appRoot, includingPropertiesForKeys: nil))
            for case let url as URL in files where url.pathExtension == "swift" {
                scanned += 1
                let text = try String(contentsOf: url, encoding: .utf8)
                for line in text.components(separatedBy: .newlines) {
                    let code = line.trimmingCharacters(in: .whitespaces)
                    guard !code.hasPrefix("//"), !code.hasPrefix("*"), !code.contains("func ") else { continue }
                    for needle in needles where code.contains(needle) {
                        callers[needle, default: []].append(url.lastPathComponent)
                    }
                }
            }

            #expect(scanned > 100, "the scan must see the app's source tree, saw \(scanned) file(s)")
            #expect(callers["triggerDailyStatsSync("] == ["AppContainer+HealthSyncOrchestrator.swift"])
            #expect(callers["triggerHRBucketSync("]?.sorted() == [
                "AppContainer+HealthSyncOrchestrator.swift",
                "HealthKitHRBucketSyncCoordinator.swift" // the protocol's forwarding default
            ])
            #expect(callers["triggerNutrientSync("]?.sorted() == [
                "AppContainer+HealthSyncOrchestrator.swift",
                "NutrientStore.swift", // first sweep right after the user grants access
                "SettingsModulesScreen.swift" // the user switches the module on
            ])
            #expect(callers["triggerEcgSync("]?.sorted() == [
                "AppContainer+HealthSyncOrchestrator.swift",
                "EcgHealthSyncStore.swift", // launch when on, the ECG switch, the first-sheet grant
                "EcgHealthSyncStore.swift",
                "EcgHealthSyncStore.swift"
            ])
            #expect(callers["SpeziCollectionTrigger.run("] == ["AppContainer+HealthSyncOrchestration.swift"])
        }
    }

#endif // !SWIFT_PACKAGE
