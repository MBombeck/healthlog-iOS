// 14-06 — the medications list, and the profile, must not lie about loading.
//
// 13-03 closed this defect in `DashboardStore` and `LabsStore`. It did not
// touch `MedicationsStore`, and `git diff v0.19.0-b266..HEAD` on that file is
// EMPTY — the store the operator says is blank carries the defect unchanged
// from the build he is running.
//
// The mechanism the operator actually meets is CANCELLATION, not an account
// switch: `ForegroundPassPlan` runs `medicationsStore.load(force: true)` as the
// first member of a pass bounded at 250 ms + 50 ms, and `force: true` always
// goes to the network. `AuthenticatedSessionLease.isCurrent` is
// `!Task.isCancelled && current()`, so the deadline trips both escapes — the
// per-emission fence (a bare `return` sitting ahead of every arm that would
// lower the flag) and the `for await` simply ending. `MedicationsScreen` gates
// its skeleton on `isLoading && medications.isEmpty && todayIntakes.isEmpty`,
// so a stranded flag over an empty list is a permanent skeleton.
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

    @Suite("Store loading truth (14-06)", .serialized)
    @MainActor
    struct StoreLoadingTruthTests {
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

        private nonisolated static let oneMedication = #"{"data":[{"id":"med-1","name":"Lisinopril","dose":"5mg"}]}"#

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

        private nonisolated static func serverError(_ request: URLRequest) -> (HTTPURLResponse, Data?) {
            (
                HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
                Data(#"{"data":null,"error":"boom"}"#.utf8)
            )
        }

        /// The endpoints one `MedicationsStore.load()` opens. The list is the one
        /// under test; the rest answer emptily so the load has its real shape.
        private nonisolated static func medicationsPayload(
            _ request: URLRequest
        ) -> (HTTPURLResponse, Data?) {
            let path = request.url?.path ?? ""
            if path.hasSuffix("/layout") {
                return json(request, #"{"data":{"mode":"cards","order":[]}}"#)
            }
            if path.hasSuffix("/intake") {
                return json(request, #"{"data":[]}"#)
            }
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

        private func makeMedicationsStore(
            _ session: MockURLProtocolSession,
            registry: AuthenticatedSessionLeaseRegistry,
            swr: Bool = true
        ) throws -> MedicationsStore {
            var coordinator: SWRCoordinator?
            if swr {
                coordinator = try SWRCoordinator(
                    cache: SWRCache(modelContainer: SWRCache.makeInMemory()),
                    reachability: StubReach()
                )
            }
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

        private func makeSettingsStore(
            _ session: MockURLProtocolSession,
            registry: AuthenticatedSessionLeaseRegistry,
            defaults: UserDefaults
        ) throws -> SettingsStore {
            let cache = try SWRCache(modelContainer: SWRCache.makeInMemory())
            return SettingsStore(
                repo: SettingsRepository(api: makeAPI(session)),
                defaults: defaults,
                swr: SWRCoordinator(cache: cache, reachability: StubReach()),
                authenticatedSessionRegistry: registry,
                userIDProvider: { Self.owner }
            )
        }

        // MARK: - 1) the mechanism the operator actually meets

        /// The foreground pass cancels `medicationLoad` at 250 ms. Cancellation
        /// ends the `for await` and trips the fence, and neither lowers the flag
        /// the `.empty` emission raised — so the skeleton stays up for the life
        /// of the process, over an empty list, which is a blank screen.
        @Test("Ein abgebrochener Vordergrund-Durchlauf lässt kein Skelett zurück")
        func cancelledMedicationsLoadCannotStrandTheSkeleton() async throws {
            let session = MockURLProtocolSession()
            defer { session.invalidate() }
            let registry = AuthenticatedSessionLeaseRegistry()
            registry.activate(ownerID: Self.owner)
            let store = try makeMedicationsStore(session, registry: registry)

            session.install { request in
                // Park the fetch on the URL-loading system's own thread so the
                // load is genuinely in flight when the deadline arrives. This is
                // the 250 ms budget, expressed as the cancellation it performs.
                Thread.sleep(forTimeInterval: 0.35)
                return Self.medicationsPayload(request)
            }

            let load = Task { await store.load(force: true) }
            let raised = await phase09Settle { await MainActor.run { store.isLoading } }
            #expect(raised, "the cold-cache `.empty` emission must raise the skeleton first")

            load.cancel()
            _ = await load.value

            #expect(
                store.isLoading == false,
                "EXPECTED_RED: a cancelled foreground pass strands the medications skeleton for the process lifetime"
            )
        }

        // MARK: - 2) and it must stop being silent

        /// Nothing in the app could previously tell "the medications load was
        /// cut off before it produced anything" from "this account has no
        /// medications". `EndpointFailureDiagnostics.classify` deliberately
        /// swallows the cancellation classes, so no endpoint line spoke for it
        /// either, and `StoreEffectDiagnostics.Store` had no `medications` case
        /// at all.
        @Test("Ein abgebrochener Ladevorgang ist zählbar, nicht stumm")
        func cancelledMedicationsLoadIsCountable() async throws {
            let session = MockURLProtocolSession()
            defer { session.invalidate() }
            let observed = RefusalLog()
            StoreEffectDiagnostics.sink = { line in observed.append(line) }
            defer { StoreEffectDiagnostics.sink = nil }

            let registry = AuthenticatedSessionLeaseRegistry()
            registry.activate(ownerID: Self.owner)
            let store = try makeMedicationsStore(session, registry: registry)

            session.install { request in
                Thread.sleep(forTimeInterval: 0.35)
                return Self.medicationsPayload(request)
            }

            let load = Task { await store.load(force: true) }
            let raised = await phase09Settle { await MainActor.run { store.isLoading } }
            #expect(raised, "the cold-cache `.empty` emission must raise the skeleton first")

            load.cancel()
            _ = await load.value

            #expect(
                observed.lines.contains("store-effect-refused store=medications reason=load_interrupted"),
                "EXPECTED_RED: an interrupted medications load is indistinguishable from an empty account"
            )
        }

        // MARK: - 3) the fence must not strand it either

        /// The account boundary moves while the fetch is in flight, and the
        /// per-emission fence refuses the emission.
        ///
        /// **This test asserted the opposite until the boundary suite corrected
        /// it, and the correction is the interesting part.** The first version
        /// demanded that the refused load lower the flag — copying 13-03's shape
        /// — and that made
        /// `AuthenticatedDashboardSettingsBoundaryTests.lateAccountATerminalStateCannotRepaintB`
        /// fail, because it requires `isLoading` to stay **true** for the account
        /// that is actually here. It is right and this was wrong: `isLoading` is
        /// an observable, so writing `false` to it from a superseded load is a
        /// retired generation publishing, and it would clear a skeleton the NEW
        /// account's in-flight load is legitimately showing.
        ///
        /// So the contract is: a superseded load publishes **nothing at all** —
        /// no medications, no error, and no flag change. The flag belongs to
        /// whoever is here now, and the production account switch settles it via
        /// `clearOnLogout()`.
        @Test("Eine überholte Anmeldung veröffentlicht gar nichts — auch kein 'fertig geladen'")
        func supersededMedicationsLoadPublishesNothingAtAll() async throws {
            let session = MockURLProtocolSession()
            defer { session.invalidate() }
            let registry = AuthenticatedSessionLeaseRegistry()
            registry.activate(ownerID: Self.owner)
            let store = try makeMedicationsStore(session, registry: registry)

            session.install { request in
                // The boundary moves underneath the in-flight fetch.
                registry.activate(ownerID: "owner-b")
                return Self.serverError(request)
            }

            await store.load()

            #expect(store.medications.isEmpty, "a refused emission publishes no medications")
            #expect(store.error == nil, "a refused emission publishes no error either")
            // And the boundary step the production account switch always runs
            // is what settles the flag — not the superseded load.
            store.clearOnLogout()
            #expect(store.isLoading == false, "the account boundary leaves no skeleton behind")
        }

        // MARK: - 4) the twin, on the direct path

        /// `MedicationsStore.loadDirect()`'s defer is conditional on the very
        /// lease that has just been retired, so on the one exit that needs it,
        /// it does not fire. This is the `LabsStore` twin 13-03 closed, in a
        /// store 13-03 never touched.
        ///
        /// The exit that needs the defer is **cancellation**, not an account
        /// switch — the old condition `authenticatedEffectIsCurrent` folds
        /// `!Task.isCancelled` in, so it evaluated `false` exactly when the flag
        /// most needed lowering. That is the mechanism the foreground pass
        /// reaches at 250 ms, and it is what this test drives.
        ///
        /// The recovery half is proven by consequence rather than by reading a
        /// private field: a later load must reach the transport again AND the
        /// list must actually appear — which is the operator's sentence, as an
        /// assertion.
        @Test("Der Direktpfad strandet nicht bei Abbruch — und die Liste erscheint danach")
        func directPathCancellationCannotStrandTheSkeleton() async throws {
            let session = MockURLProtocolSession()
            defer { session.invalidate() }
            let registry = AuthenticatedSessionLeaseRegistry()
            registry.activate(ownerID: Self.owner)
            let store = try makeMedicationsStore(session, registry: registry, swr: false)

            session.install { request in
                Thread.sleep(forTimeInterval: 0.35)
                return Self.medicationsPayload(request)
            }
            let load = Task { await store.load() }
            let raised = await phase09Settle { await MainActor.run { store.isLoading } }
            #expect(raised, "loadDirect must raise the skeleton first")
            load.cancel()
            _ = await load.value

            #expect(
                store.isLoading == false,
                "loadDirect's conditional defer skipped the one exit that needed it"
            )

            let counter = RefusalCounter()
            session.install { request in
                counter.increment()
                return Self.medicationsPayload(request)
            }
            await store.load()

            #expect(counter.value > 0, "the next load must reach the transport again")
            #expect(store.medications.count == 1, "and the medications must actually appear")
            #expect(store.isLoading == false, "with the skeleton down")
        }

        // MARK: - 5) the profile, which is why the avatar is invisible too

        /// `SettingsStore.consumeProfile` has the identical shape, and
        /// `AppContainer+Avatar` awaits `settings.load()` before it can even ask
        /// for an avatar URL — so the profile strand is why the operator's
        /// avatar is invisible as well as slow.
        ///
        /// Driven by cancellation for the same reason as the medications case:
        /// that is the exit the foreground pass and a screen dismissal actually
        /// reach, and the one the old predicate could not see.
        @Test("Das Profil strandet nicht, wenn der Ladevorgang abgebrochen wird")
        func cancelledProfileLoadCannotStrandIsLoading() async throws {
            let session = MockURLProtocolSession()
            defer { session.invalidate() }
            let suiteName = "StoreLoadingTruthTests.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }

            let registry = AuthenticatedSessionLeaseRegistry()
            registry.activate(ownerID: Self.owner)
            let store = try makeSettingsStore(session, registry: registry, defaults: defaults)

            session.install { request in
                Thread.sleep(forTimeInterval: 0.35)
                return Self.serverError(request)
            }

            let load = Task { await store.load() }
            let raised = await phase09Settle { await MainActor.run { store.isLoading } }
            #expect(raised, "the cold-cache emission must raise the skeleton first")
            load.cancel()
            _ = await load.value

            #expect(
                store.isLoading == false,
                "a cancelled profile load strands the skeleton for the process lifetime"
            )
            #expect(store.profile == nil, "and it publishes no profile")
        }

        // MARK: - 6) and it must not cross the account boundary

        /// `clearOnLogout()` resets a dozen fields and omits this one — the same
        /// omission 13-03 found in `DashboardStore`, still open here. A logout
        /// during an in-flight load hands the next account a profile that is
        /// already, permanently, loading.
        @Test("Abmelden während eines laufenden Ladevorgangs räumt das Profil-Skelett ab")
        func settingsLogoutResetsIsLoading() async throws {
            let session = MockURLProtocolSession()
            defer { session.invalidate() }
            let suiteName = "StoreLoadingTruthTests.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }

            let registry = AuthenticatedSessionLeaseRegistry()
            registry.activate(ownerID: Self.owner)
            let store = try makeSettingsStore(session, registry: registry, defaults: defaults)

            session.install { request in
                Thread.sleep(forTimeInterval: 0.35)
                return Self.serverError(request)
            }
            let load = Task { await store.load() }

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

        // MARK: - 7) the operator's own sequence, as a measurement

        /// **The question his answer leaves open.** He is unambiguous that
        /// pulling down does not help; he *believes* a relaunch does, but by his
        /// own account he waited rather than force-quitting, so the relaunch half
        /// is a belief and not an observation.
        ///
        /// Three outcomes are compatible with "pulling does nothing": the store
        /// never publishes, it publishes late, or it publishes only after a
        /// relaunch. They are not the same defect and they do not have the same
        /// fix. This test walks his exact sequence — a foreground pass cancelled
        /// at the deadline, then the pull-to-refresh `MedicationsScreen:187`
        /// actually performs (`store.load()`, NOT forced) — against a transport
        /// that answers normally afterwards, and names which outcome occurs.
        ///
        /// It carries no `EXPECTED_RED` marker on purpose: it is an observation,
        /// and its job is to report the same answer before and after the fix if
        /// that is the truth.
        @Test("Nach einem abgebrochenen Durchlauf bringt ein Pull-to-Refresh die Liste")
        func pullToRefreshAfterAnInterruptedPassPublishesTheList() async throws {
            let session = MockURLProtocolSession()
            defer { session.invalidate() }
            let registry = AuthenticatedSessionLeaseRegistry()
            registry.activate(ownerID: Self.owner)
            let store = try makeMedicationsStore(session, registry: registry)

            // 1. The foreground pass: forced, slow, cancelled at the deadline.
            session.install { request in
                Thread.sleep(forTimeInterval: 0.35)
                return Self.medicationsPayload(request)
            }
            let pass = Task { await store.load(force: true) }
            _ = await phase09Settle { await MainActor.run { store.isLoading } }
            pass.cancel()
            _ = await pass.value

            // 2. The user pulls down. This is exactly what the screen does.
            session.install { request in Self.medicationsPayload(request) }
            await store.load()

            #expect(
                store.medications.count == 1,
                "pull-to-refresh must publish the list after an interrupted pass"
            )
            #expect(
                store.isLoading == false,
                "and it must leave no skeleton behind"
            )
        }

        // MARK: - 7b) why pulling can still appear to do nothing

        /// Test 7 measures that a pull DOES publish once the interrupted request
        /// completes. So the stranded flag alone cannot produce "pulling does
        /// nothing" — something must stop the second attempt from completing
        /// too, and this names it.
        ///
        /// `SWRCoordinator.revalidateSingleFlight` collapses concurrent callers
        /// for one key into one round-trip (`:305-314`). The winner task is
        /// unstructured, so cancelling the foreground pass does NOT cancel the
        /// fetch it started — it keeps running, still registered as in-flight.
        /// A pull-to-refresh arriving while it is still in flight therefore does
        /// not issue a request of its own: it **attaches to the winner and
        /// inherits its full worst case, with no timeout of its own**.
        ///
        /// On a slow network that is indistinguishable, from the user's side,
        /// from a pull that did nothing — which is exactly "ich habe es mir
        /// einfach gemacht und gewartet". The transport count is the witness:
        /// one request served two loads.
        ///
        /// **21-03 (D-14-06-C) — what this case pins CHANGED, and it is kept
        /// rather than deleted because the old behaviour was measured truth and
        /// its replacement is a decision worth being able to read.**
        ///
        /// A real pull-to-refresh is no longer this walk. `MedicationsScreen`
        /// now calls `load(force: true, intent: .userInitiated)`, and a
        /// `.userInitiated` caller attaches for at most
        /// `SWRCoordinator.userInitiatedAttachBound` before issuing its own
        /// request — `SWRCoordinatorRefreshContractTests` owns that contract and
        /// asserts the transport sees **2**.
        ///
        /// What survives here, and what this case now pins, is the SYSTEM half:
        /// a caller that did NOT pull a screen — the foreground pass, the
        /// scenePhase hook, the screen's `.task` — still attaches to the
        /// in-flight winner for however long it takes, and the transport still
        /// sees **1**. That collapse is what keeps N identical background
        /// revalidations to one round-trip, and 21-03 would have been a bad
        /// trade if it had bought a bounded pull by breaking it. The name and
        /// the assertion message say "system caller" now, because that is what
        /// `store.load()` with no intent means.
        @Test("Ein System-Caller hängt sich an den laufenden Request statt einen eigenen zu stellen")
        func systemCallerAttachesToTheStillRunningWinner() async throws {
            let session = MockURLProtocolSession()
            defer { session.invalidate() }
            let registry = AuthenticatedSessionLeaseRegistry()
            registry.activate(ownerID: Self.owner)
            let store = try makeMedicationsStore(session, registry: registry)

            let listHits = RefusalCounter()
            session.install { request in
                if request.url?.path == "/api/medications" {
                    listHits.increment()
                    // Still in flight when the pull arrives.
                    Thread.sleep(forTimeInterval: 0.6)
                }
                return Self.medicationsPayload(request)
            }

            let pass = Task { await store.load(force: true) }
            _ = await phase09Settle { await MainActor.run { store.isLoading } }
            pass.cancel()
            _ = await pass.value

            // A system caller arrives while the cancelled pass's fetch is still
            // running. (Before 21-03 this line stood for the user's pull; a
            // pull now passes `intent: .userInitiated` and takes the bounded
            // path instead.)
            await store.load()

            #expect(
                listHits.value == 1,
                "a system caller attached to the in-flight winner rather than issuing its own request"
            )
            #expect(store.medications.count == 1, "and it published only when that winner finished")
        }

        // MARK: - 8) the vocabulary itself (control — green before and after)

        /// The line carries closed-set words and nothing else — no owner id, no
        /// generation, no route. A refusal is about the *shape* of the session
        /// boundary, and the shape is all an operator needs.
        @Test("Die neuen Refusal-Zeilen tragen nur geschlossene Wörter")
        func refusalVocabularyIsClosed() {
            #expect(
                StoreEffectDiagnostics.formatLine(store: .medications, refusal: .loadInterrupted)
                    == "store-effect-refused store=medications reason=load_interrupted"
            )
            #expect(
                StoreEffectDiagnostics.formatLine(store: .settings, refusal: .leaseUnavailable)
                    == "store-effect-refused store=settings reason=lease_unavailable"
            )
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
