// 13-03 (A1) — the dashboard must not lie about loading.
//
// The operator's A1 is "lädt manchmal extrem langsam, manchmal kommen die
// Daten gar nicht". Two of its three code-proven mechanisms are here, and both
// are the same shape: a load raises `isLoading`, an exit path leaves without
// lowering it, and the #67 inline error card is gated on `hasError &&
// !isLoading` — so the stranded flag suppresses the very resilience built for
// this symptom. The only way out on a shipped build is pull-to-refresh.
//
// Drives the REAL stores over the REAL `APIClient` on a session-scoped
// `MockURLProtocolSession` (09-13) and a real in-memory `SWRCache`, because the
// defect lives in the interaction between the SWR stream, the account fence and
// the flag — not in any one of them.

// swiftlint:disable force_unwrapping

#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import SwiftData
    import Testing

    @Suite("Dashboard loading truth (13-03)", .serialized)
    @MainActor
    struct DashboardLoadingTruthTests {
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

        private nonisolated static let owner = "owner-a"

        private func makeAPI(_ session: MockURLProtocolSession) -> APIClient {
            let keychain = InMemoryKeychain()
            try? keychain.setString("token", forKey: KeychainKey.authToken)
            let environment = AppEnvironment(
                baseURL: session.baseURL,
                bundleID: "dev.healthlog.app",
                appVersion: "0.19.0",
                buildNumber: "1"
            )
            return APIClient(
                environment: environment,
                keychain: keychain,
                sessionConfiguration: session.configuration
            )
        }

        private func makeDashboardStore(
            _ session: MockURLProtocolSession,
            registry: AuthenticatedSessionLeaseRegistry
        ) throws -> DashboardStore {
            let cache = try SWRCache(modelContainer: SWRCache.makeInMemory())
            return DashboardStore(
                repo: DashboardRepository(api: makeAPI(session)),
                swr: SWRCoordinator(cache: cache, reachability: StubReach()),
                authenticatedSessionRegistry: registry,
                userIDProvider: { Self.owner }
            )
        }

        // MARK: - 1) the fence must not strand the skeleton

        /// A cold cache emits `.empty`, which raises `isLoading`. An exit path
        /// then leaves without lowering it, and the #67 inline error card is
        /// gated on `hasError && !isLoading`, so the stranded flag suppresses
        /// the very resilience built for this symptom.
        ///
        /// **20-02 corrected this case's SECOND half, and the correction is the
        /// interesting part — it is the same correction 14-06 made to
        /// `StoreLoadingTruthTests`, one store over.** As 13-03 wrote it, this
        /// test drove SUPERSESSION (`activate(ownerID: "owner-b")` inside the
        /// handler) and demanded that the superseded load lower the flag. That
        /// was the only shape available: the predicate that can tell
        /// cancellation from supersession did not exist until 14-06 split it.
        /// It is wrong, and D-14-06-A recorded why: `isLoading` is an
        /// observable, so a retired generation writing `false` to it is a
        /// retired generation publishing — over the skeleton the account that IS
        /// here is legitimately showing (09-06's invariant, and
        /// `AuthenticatedDashboardSettingsBoundaryTests`' subject).
        ///
        /// So the contract splits along the predicate, and BOTH halves are
        /// asserted here so neither can be traded for the other:
        ///
        ///   - **cancellation, generation unchanged** — this load raised the
        ///     flag and nobody else owns it. It MUST lower it. That is 13-03's
        ///     own exit and it is untouched.
        ///   - **generation moved on** — publish nothing, "not loading"
        ///     included. `clearOnLogout()` settles it at the boundary, and it
        ///     always runs there: `dashboardStore` is in `logoutClearables`,
        ///     which `performFullLocalLogout` iterates on every path that
        ///     advances the generation.
        @Test("Eine abgewiesene Emission lässt kein Skelett zurück")
        func fencedEmissionCannotStrandIsLoading() async throws {
            let session = MockURLProtocolSession()
            defer { session.invalidate() }
            let registry = AuthenticatedSessionLeaseRegistry()
            registry.activate(ownerID: Self.owner)
            let store = try makeDashboardStore(session, registry: registry)

            session.install { request in
                // The boundary moves underneath the in-flight fetch.
                registry.activate(ownerID: "owner-b")
                return (
                    HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"data":null,"error":"boom"}"#.utf8)
                )
            }

            await store.load()

            // The fence still protects the data. Untouched by this plan.
            #expect(store.summary == nil)
            #expect(store.error == nil)
            #expect(
                store.isLoading,
                "a superseded generation publishes nothing at all, 'not loading' included"
            )
            // And the boundary step production always runs is what settles it.
            store.clearOnLogout()
            #expect(store.isLoading == false, "the account boundary leaves no skeleton behind")

            // 13-03's own exit — cancellation, generation unchanged — still
            // settles. This is the half the guard must never cost us.
            let cancellationRegistry = AuthenticatedSessionLeaseRegistry()
            cancellationRegistry.activate(ownerID: Self.owner)
            let cancelled = try makeDashboardStore(session, registry: cancellationRegistry)
            session.install { request in
                Thread.sleep(forTimeInterval: 0.35)
                return (
                    HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"data":null,"error":"boom"}"#.utf8)
                )
            }
            let load = Task { await cancelled.load() }
            let raised = await phase09Settle { await MainActor.run { cancelled.isLoading } }
            #expect(raised, "the cold-cache emission must raise the skeleton first")
            load.cancel()
            _ = await load.value
            #expect(
                cancelled.isLoading == false,
                "EXPECTED_RED: a cancelled dashboard load strands the skeleton forever"
            )
        }

        // MARK: - 2) logout must not carry the flag into the next session

        /// `clearOnLogout()` resets nine fields and omits this one, so a logout
        /// during an in-flight load hands the next account a dashboard that is
        /// already, permanently, loading.
        @Test("Abmelden während eines laufenden Ladevorgangs räumt das Skelett ab")
        func logoutResetsIsLoading() async throws {
            let session = MockURLProtocolSession()
            defer { session.invalidate() }
            let registry = AuthenticatedSessionLeaseRegistry()
            registry.activate(ownerID: Self.owner)
            let store = try makeDashboardStore(session, registry: registry)

            session.install { request in
                // Park the fetch on a real thread so the load is genuinely in
                // flight while the logout runs. The URL-loading system owns
                // this thread; the test's own actor is free.
                Thread.sleep(forTimeInterval: 0.35)
                return (
                    HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"data":null,"error":"boom"}"#.utf8)
                )
            }
            let load = Task { await store.load() }

            // The `.empty` emission from the cold cache is what raises the flag.
            let raised = await phase09Settle { await MainActor.run { store.isLoading } }
            #expect(raised, "the cold-cache emission must raise the skeleton first")

            store.clearOnLogout()

            #expect(
                store.isLoading == false,
                "EXPECTED_RED: clearOnLogout leaves isLoading true into the next session"
            )
            load.cancel()
            _ = await load.value
        }

        // MARK: - 3) the twin

        /// `LabsStore.load()`'s `defer` was conditional on the very lease that
        /// had just been retired, so on the one exit that needed it, it did not
        /// fire. It stranded two flags, not one: `isReloading` guards the
        /// method's own re-entry, so every later `load()` became a permanent
        /// no-op as well.
        ///
        /// **20-02 corrected the first half of this case for the same reason as
        /// its dashboard twin above**: it drove SUPERSESSION and demanded the
        /// superseded load settle, which is a retired generation publishing. The
        /// second, worse half — the re-entry guard must not strand — is
        /// unchanged and is what keeps the new predicate honest: it is asserted
        /// after the boundary step production always runs, because that is the
        /// sequence a device performs.
        @Test("LabsStore hat denselben Strang — und einen zweiten dazu")
        func labsTwinCannotStrandIsLoading() async throws {
            let session = MockURLProtocolSession()
            defer { session.invalidate() }
            let registry = AuthenticatedSessionLeaseRegistry()
            registry.activate(ownerID: Self.owner)
            let repository = try LabsRepository(
                api: makeAPI(session),
                outbox: OutboxQueue(inMemory: true)
            )
            let store = LabsStore(repository: repository)
            store.bindAuthenticatedSessionRegistry(registry, ownerIDProvider: { Self.owner })

            session.install { request in
                registry.activate(ownerID: "owner-b")
                return (
                    HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"data":null,"error":"boom"}"#.utf8)
                )
            }

            await store.load()

            #expect(store.lastError == nil, "a refused emission publishes nothing, not even an error")
            #expect(
                store.isLoading,
                "a superseded generation publishes nothing at all, 'not loading' included"
            )
            // The boundary step every logout path runs — `labsStore` is in
            // `logoutClearables` — and it resets BOTH flags.
            store.clearOnLogout()
            #expect(store.isLoading == false, "the account boundary leaves no skeleton behind")

            // The second flag is the worse half: `isReloading` guards re-entry,
            // so a strand there turns every later load into a permanent no-op.
            // Proven by consequence rather than by reading a private field —
            // a second load must reach the transport again.
            let counter = RefusalCounter()
            session.install { request in
                counter.increment()
                return (
                    HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"data":null,"error":"boom"}"#.utf8)
                )
            }
            // The original owner is admitted again — a re-login, or the same
            // account arriving on this device once more. The lease is
            // capturable, so the ONLY thing that could still stop this load is
            // a stranded `isReloading`.
            registry.activate(ownerID: Self.owner)
            await store.load()
            #expect(
                counter.value > 0,
                "EXPECTED_RED: a strand in isReloading makes every later load a no-op"
            )
        }

        // MARK: - 6) the refusal is no longer silent (H-A1c)

        /// A refused lease is *correct* to do nothing — publishing another
        /// account's data would be the real defect. What was wrong is that it
        /// did nothing observably, and `EndpointFailureDiagnostics` deliberately
        /// swallows the cancellation classes, so nothing else spoke for it
        /// either.
        @Test("Eine abgelehnte Lease hinterlässt eine Spur, keine Stille")
        func aRefusedLeaseIsCountable() async throws {
            let session = MockURLProtocolSession()
            defer { session.invalidate() }
            let observed = RefusalLog()
            StoreEffectDiagnostics.sink = { line in observed.append(line) }
            defer { StoreEffectDiagnostics.sink = nil }

            let cache = try SWRCache(modelContainer: SWRCache.makeInMemory())
            let registry = AuthenticatedSessionLeaseRegistry()
            registry.activate(ownerID: Self.owner)
            // No owner id → no lease can be captured at all.
            let store = DashboardStore(
                repo: DashboardRepository(api: makeAPI(session)),
                swr: SWRCoordinator(cache: cache, reachability: StubReach()),
                authenticatedSessionRegistry: registry,
                userIDProvider: { nil }
            )

            await store.load()

            #expect(observed.lines.contains("store-effect-refused store=dashboard reason=lease_unavailable"))
            // The line carries two closed-set words and nothing else.
            #expect(
                StoreEffectDiagnostics.formatLine(store: .labs, refusal: .leaseRetired)
                    == "store-effect-refused store=labs reason=lease_retired"
            )
            #expect(store.isLoading == false)
        }
    }

    private final class RefusalCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func increment() {
            lock.lock()
            defer { lock.unlock() }
            count += 1
        }

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }

    private final class RefusalLog: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []

        func append(_ line: String) {
            lock.lock()
            defer { lock.unlock() }
            storage.append(line)
        }

        var lines: [String] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

#endif
