#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing

    /// Does "Jetzt syncen" reach every enabled HealthKit pipeline? It names
    /// `HealthSyncTrigger.manual`, `manual`'s plan is `completeSet`, and the
    /// coordinator enters the orchestrator once for it.
    @Suite("Manual Apple Health sync composition")
    struct ManualHealthSyncCompositionTests {
        @Test("sync now reaches every enabled HealthKit pipeline")
        func productionCompositionIsComplete() throws {
            // The composition root is the only place that hands the readiness
            // store its route; without it "Jetzt syncen" silently does nothing.
            let wiring = try String(
                contentsOf: URL(fileURLWithPath: #filePath)
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .appendingPathComponent("HealthLog/Stores/AppContainer+Wiring.swift"),
                encoding: .utf8
            )
            #expect(wiring.contains("hkReadinessStore.attachHealthSyncRoute"))

            // "Every enabled pipeline" is a fact about the plan, not about which
            // calls someone remembered to write at the call site.
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
    }

    private actor EventRecorder {
        private(set) var events: [String] = []

        func record(_ event: String) {
            events.append(event)
        }
    }

#endif
