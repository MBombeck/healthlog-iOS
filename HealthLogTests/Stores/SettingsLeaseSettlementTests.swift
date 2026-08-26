// 20-02 — R1's genuine residual: the exit that sits ABOVE the covering defer.
//
// `SettingsStore.load()`'s `guard let sessionLease = captureAuthenticatedSession
// Lease() else { … return }` (`SettingsStore.swift:265`) sits above the covering
// defer 14-06 placed below it, so the nil-lease exit returns without settling
// anything. 14-06 made that exit *countable*
// (`recordRefusal(.leaseUnavailable, store: .settings)`) but not *settling*, and
// a flag nobody lowers is a skeleton nobody removes. Since `AppContainer+Avatar`
// awaits `settings.load()` before it can even read `profile.avatarUrl`, a
// profile that never settles is also an avatar that never appears — the lone
// "M" the operator reports.
//
// **This suite lives beside `StoreLoadingTruthTests` rather than inside it.**
// That file is at 545 lines against SwiftLint's 600-line `file_length` warning,
// and this case plus the comment it needs pushed it to 613 — a NEW warning,
// measured by `lint-strict-baseline.sh` before this file existed. Recording
// lint debt to host a test is not a trade worth making (the D-15-02-B lesson),
// so the subject gets its own file. Same instrument as its neighbour: the REAL
// `SettingsStore` over the REAL `APIClient` on a session-scoped
// `MockURLProtocolSession` and a real in-memory `SWRCache`.

// swiftlint:disable force_unwrapping

#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import SwiftData
    import Testing

    @Suite("Settings lease settlement (20-02)", .serialized)
    @MainActor
    struct SettingsLeaseSettlementTests {
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

        private nonisolated static let owner = "owner-a"

        private nonisolated static func serverError(_ request: URLRequest) -> (HTTPURLResponse, Data?) {
            (
                HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
                Data(#"{"data":null,"error":"boom"}"#.utf8)
            )
        }

        private func makeStore(
            _ session: MockURLProtocolSession,
            registry: AuthenticatedSessionLeaseRegistry,
            defaults: UserDefaults
        ) throws -> SettingsStore {
            let keychain = InMemoryKeychain()
            try? keychain.setString("token", forKey: KeychainKey.authToken)
            let api = APIClient(
                environment: AppEnvironment(
                    baseURL: session.baseURL,
                    bundleID: "dev.healthlog.app",
                    appVersion: "0.19.0",
                    buildNumber: "1"
                ),
                keychain: keychain,
                sessionConfiguration: session.configuration
            )
            let cache = try SWRCache(modelContainer: SWRCache.makeInMemory())
            return SettingsStore(
                repo: SettingsRepository(api: api),
                defaults: defaults,
                swr: SWRCoordinator(cache: cache, reachability: StubReach()),
                authenticatedSessionRegistry: registry,
                userIDProvider: { Self.owner }
            )
        }

        /// **The state this drives is a PRE-EXISTING installation's, not a fresh
        /// one** — 13-05's lesson, applied. A never-signed-in fixture reaches a
        /// nil lease trivially, with `isLoading` already false, so it would pass
        /// against the unfixed tree and prove nothing at all. The state that
        /// matters is the one a WARM install reaches when its session is
        /// revoked: a profile load is in flight with the skeleton up, the
        /// session is retired underneath it (the 401 → logout path), the
        /// in-flight load correctly publishes nothing — "not loading" included,
        /// which is 09-06's invariant and the whole reason 14-06 split the
        /// predicate — and then the surface retries. That retry is the exit
        /// under test.
        @Test("Ein zurückgezogenes Konto lässt den Profil-Ladezustand nicht stehen")
        func nilLeaseSettingsLoadStillSettlesAndSaysWhy() async throws {
            let session = MockURLProtocolSession()
            defer { session.invalidate() }
            let suiteName = "SettingsLeaseSettlementTests.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }

            let observed = RefusalLog()
            StoreEffectDiagnostics.sink = { line in observed.append(line) }
            defer { StoreEffectDiagnostics.sink = nil }

            let registry = AuthenticatedSessionLeaseRegistry()
            registry.activate(ownerID: Self.owner)
            let store = try makeStore(session, registry: registry, defaults: defaults)

            // The warm installation: a profile load is in flight, skeleton up.
            session.install { request in
                Thread.sleep(forTimeInterval: 0.35)
                return Self.serverError(request)
            }
            let inFlight = Task { await store.load() }
            let raised = await phase09Settle { await MainActor.run { store.isLoading } }
            #expect(raised, "the cold-cache emission must raise the skeleton first")

            // The session is revoked underneath it. No new account arrives.
            registry.invalidate()
            inFlight.cancel()
            _ = await inFlight.value
            #expect(
                store.isLoading,
                "precondition (14-06): a retired generation publishes nothing, 'not loading' included"
            )

            // The surface retries. There is no lease to capture any more, and
            // this is the exit that has to settle.
            await store.load()

            #expect(
                store.isLoading == false,
                "EXPECTED_RED: the nil-lease exit returns above the covering defer and strands the profile skeleton"
            )
            #expect(
                observed.lines.contains("store-effect-refused store=settings reason=lease_unavailable"),
                "and the exit stays countable — 14-06's line is not traded away for the settle"
            )
        }

        /// The settle must not become a licence to publish. A nil lease means
        /// nobody is here; the store may lower its own flag and say why, and it
        /// may do nothing else.
        @Test("Der stillgelegte Ausgang veröffentlicht nichts außer sich selbst")
        func theNilLeaseExitPublishesNothingElse() async throws {
            let session = MockURLProtocolSession()
            defer { session.invalidate() }
            let suiteName = "SettingsLeaseSettlementTests.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }

            let registry = AuthenticatedSessionLeaseRegistry()
            registry.activate(ownerID: Self.owner)
            let store = try makeStore(session, registry: registry, defaults: defaults)
            session.install { request in Self.serverError(request) }

            registry.invalidate()
            await store.load()

            #expect(store.profile == nil, "no profile")
            #expect(store.error == nil, "and no error — a refused lease is not a failure to show")
        }
    }

#endif
