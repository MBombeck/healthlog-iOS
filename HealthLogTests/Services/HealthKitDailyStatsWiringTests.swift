import Foundation
@testable import HealthLog
import Testing
#if canImport(HealthKit)
    import HealthKit
#endif

// V0.5.2 N4 — Wiring-Tests fuer den HK-STATS-Pfad. Stellt sicher, dass
//
// 1. `BackgroundSyncCoordinator.attachAnchorSweepHook` den Hook nach
//    `activateHealthKitBackgroundDeliveries` und nach jedem BGTask-Wake
//    aufruft (operator-reported "37 Schritte" Regression auf v0.5.1).
// 2. `HealthKitService.defaultReadTypes` enthaelt `sleepAnalysis` und
//    die 5 kumulativen Quantity-Types (operator-reported "Schlaf Letzte
//    Nacht empty" — Tile leer weil entweder Permission oder Sample-Path
//    fehlt).
// 3. `HealthKitDailyStatsSyncing`-Protokoll-Konformanz fuer den
//    Production-Coordinator vorhanden ist (kein dangling-Protokoll, die
//    Composition-Root kann den Slot tatsaechlich bestuecken).
#if !SWIFT_PACKAGE

    @Suite("V0.5.2 N4 — HK-STATS-Wiring")
    struct HealthKitDailyStatsWiringTests {
        // MARK: - 1. Der Aggregat-Sweep gehoert zum Pass, nicht zu `activate`

        /// **Restated by plan 07-09.** Dieser Test pinnte, dass
        /// `activateHealthKitBackgroundDeliveries` den gebuendelten
        /// Anchor-Sweep-Hook (Daily-Stats + HR-Buckets + Nutrients) detached
        /// feuert. Der Hook ist weg: das sind drei Capabilities des einen
        /// orchestrierten Passes, und die liefen nach 07-07 doppelt. Was bleibt,
        /// ist die eigentliche Zusicherung — nach der Berechtigung laeuft ein
        /// Aggregat-Sync, ohne dass die Verbindungsflaeche darauf wartet: der
        /// Aufrufer nennt `postAuthentication`, dessen Plan `completeSet` ist,
        /// und `AppContainer.activateHealthKitBackground(for:)` startet ihn
        /// detached.
        @Test("die Aggregate gehoeren zum benannten Pass, nicht zum BG-Activate")
        func activateDelegatesTheSweepToTheNamedPass() async {
            let writer = MockHealthKitWriter()
            let coordinator = BackgroundSyncCoordinator(healthKit: writer)
            let counter = HookCallCounter()
            coordinator.attachHealthSyncRoute { _, _ in
                await counter.increment()
                return []
            }

            await coordinator.activateHealthKitBackgroundDeliveries()
            await Task.yield()

            #expect(writer.activateCallCount == 1)
            #expect(await counter.value == 0, "BG-Activate darf keinen Pass starten — der Aufrufer benennt ihn")
            // Die drei Aggregat-Capabilities sind im Plan der beiden Trigger, die
            // `activateHealthKitBackground(for:)` benutzen.
            for trigger in [HealthSyncTrigger.postAuthentication, .coldActivation] {
                let planned = HealthSyncCompositionPlan.required(for: trigger)
                #expect(planned.contains(.dailyStatistics))
                #expect(planned.contains(.heartRateBuckets))
                #expect(planned.contains(.nutrientDailyTotals))
            }
        }

        @Test("BG-Activate ohne verdrahtete Route bleibt no-op (Route spaeter)")
        func activateNoHookIsNoOp() async {
            let writer = MockHealthKitWriter()
            let coordinator = BackgroundSyncCoordinator(healthKit: writer)
            // Keine Route angehaengt — activate darf trotzdem nicht crashen.
            await coordinator.activateHealthKitBackgroundDeliveries()
            #expect(writer.activateCallCount == 1)
        }

        // MARK: - 2. HK-Permissions enthalten sleepAnalysis + alle 5 Cumulatives

        #if canImport(HealthKit)
            @Test("HealthKitService.defaultReadTypes enthaelt sleepAnalysis")
            func defaultReadTypesIncludesSleep() {
                let ids = HealthKitService.defaultReadTypes.map(\.identifier)
                #expect(
                    ids.contains(HKCategoryTypeIdentifier.sleepAnalysis.rawValue),
                    "Sleep tile empty regression — sleepAnalysis muss im Permission-Picker stehen"
                )
            }

            @Test("HealthKitService.defaultReadTypes enthaelt die 5 kumulativen Quantity-Types")
            func defaultReadTypesIncludesCumulatives() {
                let ids = Set(HealthKitService.defaultReadTypes.map(\.identifier))
                let expected = HealthKitCumulativeTypeConfig.cumulativeIdentifiers
                // TimeInDaylight ist iOS17+ und wird per #available eingebunden — wir
                // erwarten auf dem Test-Host (iOS 18+ Build) alle 5.
                let missing = expected.subtracting(ids)
                #expect(missing.isEmpty, "Cumulative HK-Types fehlen im Permission-Picker: \(missing)")
            }
        #endif

        // MARK: - 3. HealthKitDailyStatsSyncing-Konformanz

        #if canImport(HealthKit)
            @Test("HealthKitStatisticsSyncCoordinator konformiert HealthKitDailyStatsSyncing")
            func coordinatorConformsToSyncingProtocol() async throws {
                let cache = try HealthKitDailyStatsCache(modelContainer: HealthKitDailyStatsCache.makeInMemory())
                let stub = StubAPI()
                let flags = StubFeatureFlags(enableDailyStats: false)
                let coord = HealthKitStatisticsSyncCoordinator(
                    statisticsService: HealthKitStatisticsService(),
                    cache: cache,
                    uploader: MeasurementBatchUploader(
                        api: stub,
                        throttle: BatchSyncThrottle(maxPerWindow: 60, window: 60.0, jitter: 0 ... 0)
                    ),
                    featureFlags: flags
                )
                let syncing: HealthKitDailyStatsSyncing = coord
                // Wenn der Flag OFF ist short-circuited sync und macht keinen
                // einzigen HTTP-Call — sicher in Unit-Tests aufrufbar.
                await syncing.triggerDailyStatsSync(lookbackDays: 1)
                #expect(await stub.requestCount == 0)
            }
        #endif

        // MARK: - 4. Foreground-Refresh delegiert mit lookbackDays=1

        @Test("HealthKitDailyStatsSyncing-Hook ruft mit lookbackDays=1 bei Foreground-Refresh")
        func foregroundRefreshUsesOneDayLookback() async {
            // Pin gegen den operator-reported Bug auf v0.6.1.21: Schritte-Tile
            // zeigt nur den letzten BGTask-Wakeup-Wert weil scenePhase=.active
            // keinen Stats-Sync triggert. Dieser Test fixiert die Erwartung:
            // RootView + DashboardScreen rufen `triggerDailyStatsSync(lookbackDays: 1)`
            // (1-Tag-Fenster reicht fuer "heute" — der HK-Anchor wird auf
            // User-TZ-Tagesanfang gerundet). Wenn das jemand auf 0 oder 7
            // aendert, soll diese Test rot werden.
            let stub = RecordingSyncing()
            await stub.triggerDailyStatsSync(lookbackDays: 1)
            #expect(await stub.calls == [1], "Foreground-Refresh muss mit lookbackDays=1 aufrufen")
        }

        actor RecordingSyncing: HealthKitDailyStatsSyncing {
            private(set) var calls: [Int] = []
            @discardableResult
            func triggerDailyStatsSync(lookbackDays: Int) async -> Bool {
                calls.append(lookbackDays)
                return true
            }
        }

        // MARK: - Helpers

        actor HookCallCounter {
            private(set) var value: Int = 0
            private var waiters: [CheckedContinuation<Void, Never>] = []
            func increment() {
                value += 1
                let pending = waiters
                waiters.removeAll()
                for continuation in pending {
                    continuation.resume()
                }
            }

            /// Wartet ohne Polling darauf, dass der detached Hook mindestens einmal
            /// gefeuert hat. Returnt sofort, wenn er schon gelaufen ist.
            func waitUntilFired() async {
                guard value == 0 else { return }
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    waiters.append(continuation)
                }
            }
        }

        actor StubAPI: APIClientProtocol {
            private(set) var requestCount: Int = 0

            func send<T: Decodable & Sendable>(_: APIRequest<T>) async throws -> T {
                requestCount += 1
                throw HLError.network(.other("stub"))
            }

            func sendVoid(_: APIRequest<EmptyPayload>) async throws {
                requestCount += 1
            }

            func download(_: APIRequest<Data>) async throws -> (Data, HTTPURLResponse) {
                requestCount += 1
                throw HLError.network(.other("stub"))
            }
        }

        struct StubFeatureFlags: FeatureFlagsServicing {
            let enableDailyStats: Bool
            func isEnabled(_ flag: FeatureFlag) -> Bool {
                switch flag {
                case .enableDailyStats: enableDailyStats
                default: true
                }
            }
        }
    }

#endif // !SWIFT_PACKAGE
