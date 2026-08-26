// Phase 07 / plan 07-09 — exact route ownership, no bypass, focused extensions.
//
// `HealthSyncTriggerRoutingTests` (Wave 0, frozen) asserts that every inventoried
// row is orchestrated and that the four entry-point files name the trigger they
// start work for. That is the *shape*. This suite asserts the two things the
// shape cannot see:
//
//   1. **No bypass survives.** The legacy split calls — the manual hook's
//      importer enumeration, the direct daily-stats fan-out, the collection
//      trigger fired beside the pass — must be absent from the call-site files,
//      not merely outnumbered by the new route. A row that says `orchestrated`
//      while its file still reaches an importer is the exact falsehood the
//      routing RED exists to catch, so it is asserted here as source text.
//   2. **Exactly once.** Each trigger owner enters the route once per wake, and
//      the entry is a named `HealthSyncTrigger` rather than an inferred one.
//
// Plus the file-size discipline the plan's Task 3 asks for: the orchestration
// bodies live in the two focused extensions, not in the two large files.

#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing

    @Suite("HealthKit sync route ownership")
    struct HealthSyncRouteOwnershipTests {
        // MARK: - No bypass

        /// Every legacy direct call this plan removed, per file that used to
        /// make it. Each pair is a real bypass that existed at the tip of 07-07
        /// and ran *in addition to* the orchestrated pass.
        private static let removedBypasses: [(file: String, token: String)] = [
            // RootView's foreground tick fired the collection trigger and then
            // the five-way daily-stats fan-out.
            ("HealthLog/App/RootView.swift", "SpeziCollectionTrigger.trigger"),
            // "Jetzt syncen" fired the collection trigger and then the split hook.
            ("HealthLog/Stores/HKReadinessStore.swift", "SpeziCollectionTrigger.trigger"),
            ("HealthLog/Stores/HKReadinessStore.swift", "manualSyncHook"),
            // The composition root enumerated the manual pass's importers.
            ("HealthLog/Stores/AppContainer+Wiring.swift", "runManualHealthSyncPass"),
            ("HealthLog/Stores/AppContainer+Wiring.swift", "triggerSyncIfEnabled"),
            // The silent push fired the trigger, then workouts, then the drain.
            ("HealthLog/Services/NotificationService+Registration.swift", "SpeziCollectionTrigger.trigger"),
            ("HealthLog/Services/NotificationService+Registration.swift", "runWorkoutSync"),
            ("HealthLog/Services/NotificationService+Registration.swift", "runOutboxDrain"),
            // The BG wakes called four HealthKit hooks in sequence.
            ("HealthLog/Services/BackgroundSyncCoordinator.swift", "currentAnchorSweepHook"),
            ("HealthLog/Services/BackgroundSyncCoordinator.swift", "currentEcgSyncHook"),
            ("HealthLog/Services/BackgroundSyncCoordinator.swift", "currentCollectionTriggerHook"),
            // The foreground refresh fanned out to five capabilities directly.
            ("HealthLog/Stores/AppContainer+HealthKitLifecycle.swift", "triggerDailyStatsSync"),
            ("HealthLog/Stores/AppContainer+HealthKitLifecycle.swift", "triggerHRBucketSync"),
            ("HealthLog/Stores/AppContainer+HealthKitLifecycle.swift", "triggerNutrientSync"),
            ("HealthLog/Stores/AppContainer+HealthKitLifecycle.swift", "triggerEcgSync"),
            ("HealthLog/Stores/AppContainer+HealthKitLifecycle.swift", "medicationHealthSyncStore")
        ]

        @Test("no inventoried entry point still reaches an importer on its own")
        func noLegacyBypassRemains() throws {
            var survivors: [String] = []
            for bypass in Self.removedBypasses {
                let contents = try Self.code(bypass.file)
                if contents.contains(bypass.token) {
                    survivors.append("\(bypass.file) :: \(bypass.token)")
                }
            }
            #expect(survivors.isEmpty, "legacy direct calls survive beside the orchestrated pass: \(survivors)")
        }

        /// Comments are stripped first. 07-06's split trap in its third form: a
        /// bypass assertion that reads a file as text can be satisfied — or
        /// falsified — by prose, and every one of these files documents the calls
        /// it used to make.
        private static func code(_ relativePath: String) throws -> String {
            try source(relativePath)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { line in
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    return !trimmed.hasPrefix("//") && !trimmed.hasPrefix("*") && !trimmed.hasPrefix("/*")
                }
                .joined(separator: "\n")
        }

        // MARK: - Exactly once, and named

        /// One expected number of entries for one token in one file.
        private struct RouteEntry {
            let file: String
            let token: String
            let count: Int
        }

        /// Each trigger owner must enter the route exactly once per wake. Counted
        /// as non-comment call sites rather than asserted in prose, because "once"
        /// is precisely what the interim double-run violated.
        @Test("each trigger owner enters the route exactly once")
        func eachOwnerEntersOnce() throws {
            let expectations: [RouteEntry] = [
                // Cold activation (T-01) and the foreground tick (T-03). 09-06
                // moved the foreground tick out of `RootView`'s sibling fan-out
                // and into the one ordered leg that also owns the dashboard
                // summary; the ownership contract is unchanged and the entry is
                // still exactly one, in the file that now owns it.
                RouteEntry(file: "HealthLog/App/RootView.swift", token: "activateHealthKitBackground(for:", count: 1),
                RouteEntry(
                    file: "HealthLog/App/ForegroundPassPlan.swift",
                    token: "refreshHealthKitDailyStatsForToday()",
                    count: 1
                ),
                // "Jetzt syncen" (T-06) and the Settings re-authorization (T-07).
                // The latter captures the route into a local first so the pass can
                // run detached — the permission surface must not wait on a first
                // history import — so the two entries read differently.
                RouteEntry(
                    file: "HealthLog/Stores/HKReadinessStore.swift",
                    token: "(HealthSyncTrigger.manual)",
                    count: 1
                ),
                RouteEntry(
                    file: "HealthLog/Stores/HKReadinessStore.swift",
                    token: "(HealthSyncTrigger.postAuthentication)",
                    count: 1
                ),
                // Silent push (T-09).
                RouteEntry(
                    file: "HealthLog/Services/NotificationService+Registration.swift",
                    token: "runHealthSyncPass(",
                    count: 1
                ),
                // The manual pass (T-12), BGProcessing (T-11), BGAppRefresh (T-10);
                // plus the one definition and the one internal guard.
                RouteEntry(
                    file: "HealthLog/Services/BackgroundSyncCoordinator.swift",
                    token: "runHealthSyncPass(",
                    count: 4
                )
            ]
            for expectation in expectations {
                let contents = try Self.code(expectation.file)
                let occurrences = contents.components(separatedBy: expectation.token).count - 1
                #expect(
                    occurrences == expectation.count,
                    "\(expectation.file) enters \(expectation.token) \(occurrences)× — expected \(expectation.count)"
                )
            }
        }

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

        // MARK: - Focused-extension discipline

        /// The plan's file-size rule: the orchestration and routing bodies belong
        /// in the two focused extensions, and the two large files may carry only a
        /// redirect. Asserted as a bound rather than a style note, because the
        /// alternative is `AppContainer.swift` growing past the `file_length`
        /// error ceiling one plan at a time.
        @Test("orchestration bodies live in the focused extensions")
        func orchestrationLivesInFocusedExtensions() throws {
            let orchestration = try Self.source("HealthLog/Stores/AppContainer+HealthSyncOrchestration.swift")
            #expect(orchestration.contains("func runHealthSyncPass("))

            let routing = try Self.source("HealthLog/Stores/AppContainer+OutboxBGDrain.swift")
            #expect(routing.contains("attachHealthSyncRoute"))

            // Neither large file gained an orchestration body.
            let container = try Self.code("HealthLog/Stores/AppContainer.swift")
            #expect(!container.contains("attachHealthSyncRoute"))
            #expect(!container.contains("HealthSyncOrchestrator("))
            #expect(Self.lineCount("HealthLog/Stores/AppContainer.swift") < 900)
            #expect(Self.lineCount("HealthLog/Services/BackgroundSyncCoordinator.swift") < 900)
        }

        private static func lineCount(_ relativePath: String) -> Int {
            ((try? source(relativePath)) ?? "").split(separator: "\n", omittingEmptySubsequences: false).count
        }

        private static func source(_ relativePath: String, file: String = #filePath) throws -> String {
            let root = URL(fileURLWithPath: file)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
        }
    }

#endif // !SWIFT_PACKAGE
