// 21-03 — `MedicationsStore.load()` and its overlapping triggers.
//
// `MedicationsScreen` has four load triggers (`.task`, `.onAppear force: true`,
// `.hlPullToRefresh`, the scenePhase hook) and `load()` has no coalescing, so
// overlapping triggers each open their own four streams.
//
// **What 21-03 shipped, and what it did not.** The pull itself is fixed: it now
// passes `force: true, intent: .userInitiated` and takes the bounded-attach
// path in `SWRCoordinator` (D-14-06-C, closed). The COALESCING half
// (D-14-06-B) was written, worked, and was reverted — it needs a shared `Task`
// handle inside `MedicationsStore.swift`, which moves 11 effects from `load-1`
// to a helper symbol and adds a new `owned-task` hit to the frozen Phase-06
// effect census. A 21-xx plan may only ever write `removed-hit` there, so the
// change cannot land in this phase. It is D-21-03-A, with the working shape and
// its two hard-won regressions recorded.
//
// The fix that must NEVER be taken is the obvious one. `LabsStore`'s
// `guard !isReloading` is precisely what 13-03 found had turned every later
// `load()` into a permanent no-op once it stranded, and the store whose symptom
// is "pulling down does nothing" is the last place to reintroduce that shape.
// D-14-06-B forbids it by name. So this suite asserts, today and after any
// future coalescer, that every overlapping caller COMPLETES and the list is
// published — the assertions a latch would fail.
//
// The drive witness is `SWRSignpost`'s recorder, from 21-01: every `observe`
// performs exactly one `swr.read.fetch` for its key, so counting those records
// counts SWR drives directly. A network count would prove nothing — the SWR
// layer's single-flight already collapses concurrent revalidations of one key,
// so the duplicated work is invisible at the socket and plain at the cache.

// swiftlint:disable force_unwrapping

#if !SWIFT_PACKAGE

    import Foundation
    @testable import HealthLog
    import SwiftData
    import Testing

    @Suite("MedicationsStore load overlap (D-14-06-B / D-21-03-A)", .serialized)
    @MainActor
    struct MedicationsLoadCoalescingTests {
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

        private final class Counter: @unchecked Sendable {
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

        private nonisolated static let owner = "owner-a"
        private nonisolated static let oneMedication =
            #"{"data":[{"id":"med-1","name":"Lisinopril","dose":"5mg"}]}"#

        private nonisolated static func json(
            _ request: URLRequest,
            _ body: String
        ) -> (HTTPURLResponse, Data?) {
            (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(body.utf8)
            )
        }

        private nonisolated static func medicationsPayload(
            _ request: URLRequest
        ) -> (HTTPURLResponse, Data?) {
            let path = request.url?.path ?? ""
            if path.hasSuffix("/layout") { return json(request, #"{"data":{"mode":"cards","order":[]}}"#) }
            if path.hasSuffix("/intake") { return json(request, #"{"data":[]}"#) }
            return json(request, oneMedication)
        }

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

        private func makeStore(
            _ session: MockURLProtocolSession,
            registry: AuthenticatedSessionLeaseRegistry
        ) throws -> MedicationsStore {
            let coordinator = try SWRCoordinator(
                cache: SWRCache(modelContainer: SWRCache.makeInMemory()),
                reachability: StubReach()
            )
            let store = try MedicationsStore(
                repo: MedicationsRepository(
                    api: makeAPI(session),
                    outbox: OutboxQueue(inMemory: true)
                ),
                swr: coordinator
            )
            store.bindAuthenticatedSessionRegistry(registry, ownerIDProvider: { Self.owner })
            return store
        }

        /// How many times `medicationsList` was read out of the cache — one per
        /// `observe`, so one per SWR drive.
        private func medicationsListReads(_ recorder: SWRSignpost.Recorder) -> Int {
            recorder.records(for: .readFetch)
                .filter { $0.key == CacheKey.medicationsList.canonicalString }
                .count
        }

        // MARK: - Today's drive count, recorded as the baseline D-21-03-A moves

        @Test("Vier überlappende System-Trigger öffnen heute vier SWR-Durchläufe — die Zahl, die D-21-03-A senkt")
        func fourOverlappingSystemTriggersDriveTheSWRLayerOncePerTrigger() async throws {
            let session = MockURLProtocolSession()
            defer { session.invalidate() }
            let registry = AuthenticatedSessionLeaseRegistry()
            registry.activate(ownerID: Self.owner)
            let store = try makeStore(session, registry: registry)

            session.install { request in
                if request.url?.path == "/api/medications" {
                    // Slow enough that all four triggers genuinely overlap.
                    Thread.sleep(forTimeInterval: 0.3)
                }
                return Self.medicationsPayload(request)
            }

            let recorder = SWRSignpost.Recorder()
            SWRSignpost.installRecorder(recorder)
            defer { SWRSignpost.installRecorder(nil) }

            let completions = Counter()
            async let first: Void = { await store.load()
                completions.increment()
            }()
            async let second: Void = { await store.load()
                completions.increment()
            }()
            async let third: Void = { await store.load(force: true)
                completions.increment()
            }()
            async let fourth: Void = { await store.load()
                completions.increment()
            }()
            _ = await (first, second, third, fourth)

            // This ran RED against a working coalescer during 21-03 and is kept
            // as the recorded baseline rather than deleted, because the number
            // is the whole content of D-21-03-A: four overlapping triggers open
            // four SWR drives for one key. The coalescer that makes it 1 was
            // written and reverted — it needs a shared `Task` handle in this
            // file, and that moves 11 effects out of `load-1` and adds an
            // `owned-task` hit to the FROZEN Phase-06 effect census, which a
            // 21-xx plan may not disposition.
            #expect(
                medicationsListReads(recorder) == 4,
                "one SWR drive per trigger is today's behaviour; D-21-03-A is the plan to make it 1"
            )

            // The half that must never regress, whatever the count becomes:
            // every caller is SERVED, not refused. A latch would satisfy a
            // count of 1 and fail these two, which is why they are asserted
            // here and not only alongside the fix.
            #expect(completions.value == 4, "every overlapping caller must complete, not be dropped")
            #expect(store.medications.count == 1, "and the list must actually be published")
        }

        // MARK: - PIN — a user-initiated pull is never coalesced away

        @Test("PIN: Ein user-initiierter Pull während eines laufenden System-Loads ist niemals ein No-op")
        func aUserInitiatedPullIsNeverSwallowedByAnInFlightSystemLoad() async throws {
            let session = MockURLProtocolSession()
            defer { session.invalidate() }
            let registry = AuthenticatedSessionLeaseRegistry()
            registry.activate(ownerID: Self.owner)
            let store = try makeStore(session, registry: registry)

            let listHits = Counter()
            session.install { request in
                if request.url?.path == "/api/medications" {
                    listHits.increment()
                    Thread.sleep(forTimeInterval: 0.3)
                }
                return Self.medicationsPayload(request)
            }

            // A background load is in flight; the user pulls.
            let background = Task { await store.load() }
            try await Task.sleep(for: .milliseconds(50))
            await store.load(force: true, intent: .userInitiated)
            await background.value

            // The pull published a list. The precise transport count is the
            // coordinator's contract (SWRCoordinatorRefreshContractTests owns
            // it); what this pins is the store-level property D-14-06-B is
            // about — a pull is never turned into a no-op by an in-flight load,
            // which is exactly what a `guard !isReloading` latch would do.
            #expect(store.medications.count == 1, "the pull must publish the list")
            #expect(listHits.value >= 1, "the pull must not have been silently dropped")
            #expect(store.isLoading == false, "and it must not strand the skeleton flag")
        }
    }

#endif

// swiftlint:enable force_unwrapping
