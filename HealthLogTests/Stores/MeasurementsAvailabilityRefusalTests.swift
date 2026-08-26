// 22-01 (R4 / V1S-INSIGHTS) — the three silent exits of `loadAvailability()`.
//
// 20-01 measured R4 over real sockets and recorded the verdict in
// `.planning/active/v1-submission/R4-ANSWER.md`: a congested availability read
// that loses its race is never completed afterwards, and — the part that made
// four investigations misfire — it says NOTHING when it fails. The console
// check that was supposed to decide the question ("filter on
// `store-effect-refused store=measurements`") could not see this leg at all,
// so its silence was read as evidence.
//
// R4-ANSWER §4 item 2 originally named TWO silent exits. That was an
// undercount, corrected on 2026-08-24: `MeasurementsStore+Availability.swift`
// has THREE.
//
//   :20  `guard let lease = captureAuthenticatedSessionLease() else { return }`
//   :23  `guard authenticatedEffectIsCurrent(lease) else { return }`  ← SUCCESS
//        path. This is the LOST-RACE exit: the one a read that was cancelled
//        at an 800 ms dwell takes *after* the wire returns, and therefore the
//        exit most likely to fire in the operator's own scenario.
//   :29  the `catch`, which writes an `HLLog.api.info` line and nothing
//        countable — with its own inner stale-lease bare return at :30.
//
// A RED written to the letter of the uncorrected §4 would assert one refusal
// line and leave the `:23` leg mute. One case per exit, four in total.
//
// **Word choice is part of the contract.** 14-06 documented the distinction
// this file leans on (`AuthenticatedSessionLease.ownsRegistryGeneration`):
// `isCurrent` folds cancellation and supersession together, and the two are
// very different facts. A superseded generation says "this result belongs to
// an account that is no longer here" (`lease_retired`); a cancelled read whose
// generation is intact says "there was no result at all, and the surface was
// left waiting for one" (`load_interrupted`). Emitting `lease_retired` for a
// plain cancellation would send the next investigation chasing an account
// switch that never happened — which is precisely the class of error this
// phase exists to end. The `:23` case below therefore drives BOTH shapes of
// its one exit.

#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import Testing

    @Suite("MeasurementsAvailabilityRefusalTests — jeder Ausgang spricht (22-01)", .serialized)
    @MainActor
    struct MeasurementsAvailabilityRefusalTests {
        // MARK: - Instruments

        /// Refusal observation that a parallel suite cannot silently switch off.
        ///
        /// `StoreEffectDiagnostics.sink` is ONE process-global slot: five suites
        /// already assign it and clear it in a `defer`. A suite that clears the
        /// slot while this one is mid-case would leave these assertions reading an
        /// empty log and going red for a reason that has nothing to do with the
        /// store — the mirror image of the `MockURLProtocol.handler` hole 09-10
        /// inventoried. The additive observer registry (22-01) exists so this
        /// suite adds an observer instead of taking the slot.
        private final class RefusalWindow: @unchecked Sendable {
            private let lock = NSLock()
            private var storage: [String] = []
            private var token: UUID?

            func start() {
                token = StoreEffectDiagnostics.addRefusalObserver { [weak self] line in
                    guard let self else { return }
                    lock.lock()
                    defer { lock.unlock() }
                    storage.append(line)
                }
            }

            func stop() {
                if let token { StoreEffectDiagnostics.removeRefusalObserver(token) }
                token = nil
            }

            /// Drop everything observed so far — the window opens immediately
            /// before the single awaited call each assertion is about.
            func reset() {
                lock.lock()
                defer { lock.unlock() }
                storage.removeAll()
            }

            /// Only this store's refusals. The line carries two closed-set words
            /// and no identity at all (13-03's privacy rule), so the window is
            /// kept as narrow as one `await`.
            var measurementsLines: [String] {
                lock.lock()
                defer { lock.unlock() }
                return storage.filter { $0.contains("store=measurements") }
            }
        }

        /// A transport that parks until the test releases it — the wire the
        /// operator is behind, expressed as a continuation rather than a sleep.
        private actor TransportGate {
            private var release: CheckedContinuation<any Sendable, any Error>?
            private var entryWaiters: [CheckedContinuation<Void, Never>] = []
            private var requested = false

            func awaitRelease() async throws -> any Sendable {
                requested = true
                let waiters = entryWaiters
                entryWaiters.removeAll()
                for waiter in waiters {
                    waiter.resume()
                }
                return try await withCheckedThrowingContinuation { continuation in
                    self.release = continuation
                }
            }

            func waitUntilRequested() async {
                if requested { return }
                await withCheckedContinuation { continuation in
                    entryWaiters.append(continuation)
                }
            }

            func answer(_ value: any Sendable) {
                release?.resume(returning: value)
                release = nil
            }
        }

        private nonisolated static let ownerID = "22-01-availability-owner"
        private nonisolated static let successorID = "22-01-availability-successor"

        /// The seeded summaries slice — the same server `MeasurementType` keys
        /// `scripts/fixtures/r4-availability-seed.json` carries.
        private nonisolated static let summaries = MeasurementAvailabilityDTO(summaries: [
            "WEIGHT": .init(count: 412),
            "BLOOD_PRESSURE_SYS": .init(count: 88),
            "PULSE": .init(count: 1904),
            "RESTING_HEART_RATE": .init(count: 260)
        ])

        private nonisolated static let seededKinds: Set<MetricKind> = [.weight, .bloodPressure, .pulse, .restingHeartRate]

        private nonisolated static func line(_ reason: String) -> String {
            "store-effect-refused store=measurements reason=\(reason)"
        }

        private func makeStore(
            api: StubAPIClient,
            admitted: Bool = true
        ) throws -> (MeasurementsStore, AuthenticatedSessionLeaseRegistry) {
            let repo = try MeasurementsRepository(api: api, outbox: OutboxQueue(inMemory: true))
            let registry = AuthenticatedSessionLeaseRegistry()
            if admitted { registry.activate(ownerID: Self.ownerID) }
            let store = MeasurementsStore(repo: repo, userIDProvider: { Self.ownerID })
            store.bindAuthenticatedSessionRegistry(registry)
            return (store, registry)
        }

        // MARK: - Exit 1 of 3 — the nil lease (`:20`)

        @Test("Ohne zugelassene Sitzung verweigert die Verfuegbarkeits-Lese zaehlbar")
        func nilLeaseExitRecordsARefusal() async throws {
            let api = StubAPIClient()
            await api.setHandler { _ in Self.summaries }
            // Never admitted → `capture(ownerID:)` finds no owner → nil lease.
            let (store, _) = try makeStore(api: api, admitted: false)

            let window = RefusalWindow()
            window.start()
            defer { window.stop() }
            window.reset()
            let published = await store.loadAvailability()

            #expect(published == false, "a refused read reports that it published nothing")
            try #require(
                window.measurementsLines == [Self.line("lease_unavailable")],
                """
                EXPECTED_RED: the nil-lease exit at MeasurementsStore+Availability.swift:20 returns bare, \
                so an availability read that never started is invisible to every operator diagnostic
                """
            )
            #expect(store.availableKinds.isEmpty, "a refused read must publish nothing")
        }

        // MARK: - Exit 2 of 3 — the SUCCESS-path stale lease (`:23`), the lost race

        @Test("Der Waechter auf dem Erfolgspfad spricht: verdraengte Sitzung und abgebrochene Lese")
        func successPathStaleLeaseExitRecordsARefusal() async throws {
            let window = RefusalWindow()
            window.start()
            defer { window.stop() }

            // ── Shape A — a PRE-EXISTING installation, not a fresh one. A warm
            //    store that already knows a kind from an earlier session, whose
            //    session is superseded while the availability read is in flight.
            //    (13-05's lesson: drive the state a real device is in.)
            let gate = TransportGate()
            let api = StubAPIClient()
            await api.setHandler { _ in try await gate.awaitRelease() }
            let (warmStore, registry) = try makeStore(api: api)
            warmStore.availableKinds = [.weight]

            window.reset()
            let inFlight = Task { @MainActor in await warmStore.loadAvailability() }
            await gate.waitUntilRequested()
            registry.invalidate()
            registry.activate(ownerID: Self.successorID)
            await gate.answer(Self.summaries)
            _ = await inFlight.value

            try #require(
                window.measurementsLines == [Self.line("lease_retired")],
                """
                EXPECTED_RED: the success-path stale-lease guard at MeasurementsStore+Availability.swift:23 \
                returns bare — the lost-race exit, the one the operator's own scenario takes, records nothing
                """
            )
            #expect(
                warmStore.availableKinds == [.weight],
                "the superseded result must not reach the successor's strip"
            )

            // ── Shape B — the same exit, reached the way the operator reaches
            //    it: the container's `.task` is cancelled at a short dwell and
            //    the wire answers AFTERWARDS. The generation never moved, so the
            //    honest word is `load_interrupted`, not `lease_retired`.
            let dwellGate = TransportGate()
            let dwellAPI = StubAPIClient()
            await dwellAPI.setHandler { _ in try await dwellGate.awaitRelease() }
            let (dwellStore, _) = try makeStore(api: dwellAPI)
            dwellStore.availableKinds = [.weight]

            window.reset()
            let dwell = Task { @MainActor in await dwellStore.loadAvailability() }
            await dwellGate.waitUntilRequested()
            dwell.cancel()
            await dwellGate.answer(Self.summaries)
            _ = await dwell.value

            #expect(
                window.measurementsLines == [Self.line("load_interrupted")],
                "a cancelled read whose generation is intact must say so, not blame an account switch"
            )
            #expect(dwellStore.availableKinds == [.weight], "a cancelled read must publish nothing")
        }

        // MARK: - Exit 3 of 3 — the catch (`:29-33`)

        @Test("Ein terminaler Fehler der Verfuegbarkeits-Lese ist zaehlbar")
        func terminalErrorExitRecordsARefusal() async throws {
            let api = StubAPIClient()
            await api.setHandler { _ in throw HLError.offline }
            let (store, _) = try makeStore(api: api)

            let window = RefusalWindow()
            window.start()
            defer { window.stop() }
            window.reset()
            let published = await store.loadAvailability()

            #expect(published == false, "a failed read reports that it published nothing")
            try #require(
                window.measurementsLines == [Self.line("load_failed")],
                """
                EXPECTED_RED: the catch at MeasurementsStore+Availability.swift:29-33 writes an HLLog line \
                and nothing countable, so a terminal availability failure has no signature to filter on
                """
            )
            #expect(store.availableKinds.isEmpty, "a failed read must publish nothing")
        }

        @Test("Eine abgebrochene Verfuegbarkeits-Lese ist von einem leeren Konto unterscheidbar")
        func cancelledLoadExitRecordsARefusal() async throws {
            let api = StubAPIClient()
            await api.setHandler { _ in throw CancellationError() }
            let (store, _) = try makeStore(api: api)

            let window = RefusalWindow()
            window.start()
            defer { window.stop() }
            window.reset()
            let published = await store.loadAvailability()

            #expect(published == false, "an interrupted read reports that it published nothing")
            try #require(
                window.measurementsLines == [Self.line("load_interrupted")],
                """
                EXPECTED_RED: a cancelled availability read is indistinguishable from an account that \
                genuinely has no measurements — the ambiguity that made R4 survive four attempts
                """
            )
            #expect(store.availableKinds.isEmpty, "an interrupted read must publish nothing")
        }

        // MARK: - The healthy bound (PIN — green by construction, no EXPECTED_RED)

        /// R4-ANSWER §4 item 3. Row 1 of the decision table on a healthy wire was
        /// **10 kinds in 0.006 s with zero refusals**. This pins the shape of that
        /// row in-process so 21-02's decode move cannot silently regress it. The
        /// ceiling is a generous tripwire, not a microbenchmark.
        @Test("Pin: eine ununterbrochene Lese veroeffentlicht jeden Kind ohne eine einzige Verweigerung")
        func uninterruptedReadPublishesEverySeededKindWithoutRefusals() async throws {
            let api = StubAPIClient()
            await api.setHandler { _ in Self.summaries }
            let (store, _) = try makeStore(api: api)

            let window = RefusalWindow()
            window.start()
            defer { window.stop() }
            window.reset()
            let started = Date()
            let published = await store.loadAvailability()
            let elapsed = Date().timeIntervalSince(started)

            #expect(published, "a healthy read reports that it published")
            #expect(store.availableKinds == Self.seededKinds, "every seeded kind must light its pill")
            #expect(window.measurementsLines.isEmpty, "a healthy read refuses nothing")
            #expect(elapsed < 1.0, "the healthy bound is a tripwire for the decode path, observed \(elapsed)s")
        }
    }

#endif
