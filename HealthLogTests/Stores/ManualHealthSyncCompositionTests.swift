#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing

    /// **Restated by plan 07-09 — the same question, a different answer.**
    ///
    /// This suite has always asked "does 'Jetzt syncen' reach every enabled
    /// HealthKit pipeline?". Until now it answered by *enumerating* the pipelines
    /// the manual hook happened to call: workouts, the aggregate anchor sweep,
    /// ECG, the Mood mirror, the Apple-medication mirror. That enumeration was
    /// the defect the phase exists to remove — it named a different set than the
    /// foreground tick and the background wakes did, nobody could see that from
    /// any one call site, and once the orchestrated pass existed the manual tap
    /// ran both sets. The question is now answered by the composition:
    /// "Jetzt syncen" names `HealthSyncTrigger.manual`, and `manual`'s plan is
    /// `completeSet`.
    @Suite("Manual Apple Health sync composition")
    struct ManualHealthSyncCompositionTests {
        @Test("sync now reaches every enabled HealthKit pipeline")
        func productionCompositionIsComplete() throws {
            let root = repositoryRoot()
            let readiness = try source("HealthLog/Stores/HKReadinessStore.swift", root: root)
            let background = try source("HealthLog/Services/BackgroundSyncCoordinator.swift", root: root)
            let wiring = try source("HealthLog/Stores/AppContainer+Wiring.swift", root: root)

            // One route, named, and the old split hook is gone from the store.
            #expect(readiness.contains("await healthSyncRoute?(HealthSyncTrigger.manual)"))
            #expect(readiness.contains("backgroundSync.reactivateHealthKitBackgroundDeliveries()"))
            #expect(!readiness.contains("await manualSyncHook?()"))
            #expect(background.contains("func runManualHealthSyncPass() async"))
            #expect(background.contains("runHealthSyncPass(HealthSyncTrigger.manual)"))
            #expect(wiring.contains("hkReadinessStore.attachHealthSyncRoute"))
            #expect(wiring.contains("runHealthSyncPass(trigger)"))
            // The three split calls the manual hook used to make must be absent —
            // they are capabilities of the pass now, not a list at a call site.
            #expect(!wiring.contains("bgSync.runManualHealthSyncPass()"))
            #expect(!wiring.contains("moodHealthSyncStore.triggerSyncIfEnabled()"))
            #expect(!wiring.contains("medicationHealthSyncStore.triggerSyncIfEnabled()"))

            // …and "every enabled pipeline" is now a fact about the plan rather
            // than about which calls someone remembered to write.
            #expect(HealthSyncCompositionPlan.required(for: .manual) == HealthSyncCompositionPlan.completeSet)
            #expect(HealthSyncCompositionPlan.installed(for: .manual) == HealthSyncCompositionPlan.completeSet)
        }

        @Test("the manual pass enters the orchestrator exactly once, as .manual")
        func manualPassEntersOneNamedRoute() async {
            let writer = MockHealthKitWriter()
            let coordinator = BackgroundSyncCoordinator(healthKit: writer)
            let order = EventRecorder()
            coordinator.attachHealthSyncRoute { trigger, _ in
                await order.record("pass-\(trigger.rawValue)")
                return Array(HealthSyncCompositionPlan.completeSet)
            }

            await coordinator.runManualHealthSyncPass()

            #expect(await order.events == ["pass-manual"])
        }

        @Test("manual reactivation does not start a pass at all")
        func manualReactivationSkipsBootstrapSweep() async {
            let writer = MockHealthKitWriter()
            let coordinator = BackgroundSyncCoordinator(healthKit: writer)
            let recorder = EventRecorder()
            coordinator.attachHealthSyncRoute { trigger, _ in
                await recorder.record("pass-\(trigger.rawValue)")
                return []
            }

            await coordinator.reactivateHealthKitBackgroundDeliveries()
            await Task.yield()

            #expect(writer.activateCallCount == 1)
            #expect(await recorder.events.isEmpty)
        }

        private func source(_ relativePath: String, root: URL) throws -> String {
            try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
        }

        private func repositoryRoot(file: String = #filePath) -> URL {
            URL(fileURLWithPath: file)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
        }
    }

    private actor EventRecorder {
        private(set) var events: [String] = []

        func record(_ event: String) {
            events.append(event)
        }
    }

#endif
