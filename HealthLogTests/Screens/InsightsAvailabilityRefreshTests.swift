// 22-01 (R4 / V1S-INSIGHTS) — row 3 of the decision table, inverted.
//
// `.planning/active/v1-submission/R4-ANSWER.md` finding (c): after an
// interrupted availability read, pull-to-refresh leaves `availableKinds` at 0
// **by construction**. `loadAvailability()` had exactly ONE production call
// site — the `.task` at `InsightsContainerScreen.swift:198` — and
// `InsightsScreen`'s `refreshable` block did not call it. That block's own
// comment reads "if you add a card here that reads from a new store, ADD ITS
// LOAD HERE TOO. Otherwise pull-to-refresh feels half-broken." The rule was
// written down in the file that broke it.
//
// **Why this file reads source text.** A harness can model a fixed refreshable
// block perfectly well while the real view closure still omits the call, and
// then "R4 fixed" is a green test over a screen that is unchanged. The wiring
// is therefore pinned in the SOURCE (16-03's technique on the transparency
// page), and the behaviour — that a second drive genuinely reaches the
// transport rather than short-circuiting inside the 5-minute SWR TTL — is
// pinned separately. Neither half alone would be worth anything.

#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import SwiftData
    import Testing

    @Suite("InsightsAvailabilityRefreshTests — der Zug repariert die Verfuegbarkeit (22-01)")
    @MainActor
    struct InsightsAvailabilityRefreshTests {
        private final class StubReach: ReachabilityProviding, @unchecked Sendable {
            var isOnlineStream: AsyncStream<Bool> {
                get async {
                    AsyncStream { continuation in
                        continuation.yield(true)
                        continuation.finish()
                    }
                }
            }

            func isCurrentlyOnline() async -> Bool {
                true
            }
        }

        private actor CallCount {
            private(set) var value = 0
            func increment() -> Int {
                value += 1
                return value
            }
        }

        private nonisolated static let ownerID = "22-01-refresh-owner"

        private nonisolated static let summaries = MeasurementAvailabilityDTO(summaries: [
            "WEIGHT": .init(count: 412),
            "BLOOD_PRESSURE_SYS": .init(count: 88),
            "PULSE": .init(count: 1904),
            "RESTING_HEART_RATE": .init(count: 260)
        ])

        private nonisolated static let seededKinds: Set<MetricKind> = [.weight, .bloodPressure, .pulse, .restingHeartRate]

        private func makeStore(api: StubAPIClient, swr: SWRCoordinator? = nil) throws -> MeasurementsStore {
            let repo = try MeasurementsRepository(api: api, outbox: OutboxQueue(inMemory: true), swr: swr)
            let registry = AuthenticatedSessionLeaseRegistry()
            registry.activate(ownerID: Self.ownerID)
            let store = MeasurementsStore(repo: repo, swr: swr, userIDProvider: { Self.ownerID })
            store.bindAuthenticatedSessionRegistry(registry)
            return store
        }

        // MARK: - The wiring, pinned where it lives

        @Test("Nach einer unterbrochenen Lese stellt der Zug die Verfuegbarkeit wieder her")
        func pullToRefreshRedrivesAvailability() async throws {
            let source = try Self.source("HealthLog/Screens/Insights/InsightsScreen.swift")
            let block = try #require(
                Self.refreshableBlock(in: source),
                "the pull-to-refresh fan-out block must be findable in InsightsScreen.swift"
            )
            try #require(
                block.contains("measurementsStore.loadAvailability()"),
                """
                EXPECTED_RED: InsightsScreen's pull-to-refresh block never calls \
                measurementsStore.loadAvailability(), so no pull the operator performs can repair an \
                interrupted availability read — R4-ANSWER finding (c)
                """
            )

            // The behaviour that wiring buys: the first read is cut off and
            // publishes nothing (row 2); the second drive — the leg the pull now
            // carries — reaches the transport and publishes (row 3, inverted).
            let calls = CallCount()
            let api = StubAPIClient()
            await api.setHandler { _ in
                if await calls.increment() == 1 { throw CancellationError() }
                return Self.summaries
            }
            let store = try makeStore(api: api)

            await store.loadAvailability()
            #expect(store.availableKinds.isEmpty, "the interrupted read leaves the strip short — R4 row 2")

            await store.loadAvailability()
            #expect(store.availableKinds == Self.seededKinds, "the pull's leg restores every kind — R4 row 3")
            #expect(await calls.value == 2, "the re-drive must reach the transport, not be swallowed")
        }

        // MARK: - The TTL question STATE.md handed forward (PIN — no EXPECTED_RED)

        /// 21-03 found `MedicationsScreen`'s pull was a no-op *by construction*
        /// because it omitted `force` inside a 60 s TTL. `loadAvailability()`
        /// sits behind the 5-minute `.measurementAvailability` SWR key, so the
        /// same question has to be asked here rather than assumed away.
        ///
        /// The answer is that no `force` threading is needed, and this pins why:
        /// the interrupted read wrote NOTHING through the cache, so the second
        /// drive has no fresh row to short-circuit on and goes to the wire. (And
        /// when a row *does* exist, `fetchCachingFirst` returns its value —
        /// which publishes the kinds too. Both branches of the ladder end with a
        /// populated strip; only the medications shape ended with nothing.)
        @Test("Pin: die Fuenf-Minuten-TTL macht den zweiten Zug nicht zum No-op")
        func swrTtlDoesNotSwallowTheRedrive() async throws {
            let swr = try SWRCoordinator(
                cache: SWRCache(modelContainer: SWRCache.makeInMemory()),
                reachability: StubReach()
            )
            let calls = CallCount()
            let api = StubAPIClient()
            await api.setHandler { _ in
                if await calls.increment() == 1 { throw CancellationError() }
                return Self.summaries
            }
            let store = try makeStore(api: api, swr: swr)

            await store.loadAvailability()
            #expect(store.availableKinds.isEmpty, "nothing was written through, so nothing is cached")

            await store.loadAvailability()
            #expect(store.availableKinds == Self.seededKinds, "the second drive publishes behind the same TTL")
        }

        // MARK: - Source access

        private nonisolated static func source(_ relativePath: String, file: String = #filePath) throws -> String {
            let root = URL(fileURLWithPath: file)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
        }

        /// The `hlPullToRefresh` fan-out closure, from its opening brace to the
        /// `.task` mirror that follows it.
        private nonisolated static func refreshableBlock(in source: String) -> String? {
            guard let start = source.range(of: ".hlPullToRefresh {") else { return nil }
            guard let end = source.range(of: "\n        .task {", range: start.upperBound ..< source.endIndex) else { return nil }
            return String(source[start.upperBound ..< end.lowerBound])
        }
    }

#endif
