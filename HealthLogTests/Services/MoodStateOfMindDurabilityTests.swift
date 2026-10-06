import Foundation
#if canImport(HealthKit)
    import HealthKit
#endif
@testable import HealthLog
import os
import Testing

// swiftlint:disable force_unwrapping

#if canImport(HealthKit)

    /// **Phase 07 / plan 07-05 — how a State-of-Mind page reaches its anchor.**
    ///
    /// The Wave-0 RED (`MoodImportDurabilityTests/enqueueFailureHoldsAnchor`)
    /// states the rule. This suite states the mapping that feeds it: which
    /// repository outcome is progress, which one is a hole, and what the two
    /// produce when the shared commit rule is asked about the page they build.
    @Suite("State of Mind — outcome classification and the anchor it produces", .mockURLSession)
    struct MoodStateOfMindDurabilityTests {
        private static let entry = MoodEntry(
            id: "local-1",
            recordedAt: Date(timeIntervalSince1970: 1_783_000_000),
            score: 3
        )

        @Test("An accepted or queued write is progress; a lost enqueue is not")
        func classificationSeparatesQueuedFromLost() {
            #expect(
                MoodStateOfMindImporter.classification(of: .accepted(Self.entry)) == .terminalAccepted
            )
            #expect(
                MoodStateOfMindImporter.classification(
                    of: .queued(Self.entry, transport: .offline)
                ) == .terminalAccepted
            )
            #expect(
                MoodStateOfMindImporter.classification(of: .enqueueLost(.notPersisted("outbox lost"))) == .nonterminal
            )
        }

        /// Deliberate, and the reason is written down in the production doc
        /// comment: a refusal a retry cannot fix would otherwise turn one
        /// malformed sample into a permanently stalled importer. It is the same
        /// call the medication path makes for `unstable_external_id`.
        @Test("A refusal a retry cannot fix is terminal, not a permanent hold")
        func aNonRetriableRefusalIsTerminal() {
            #expect(
                MoodStateOfMindImporter.classification(
                    of: .rejected(.server(status: 422, code: nil, message: "Validation failed"))
                ) == .terminalAccepted
            )
        }

        /// #115 / 0.3 — the one refusal that is about the account, not the
        /// sample. The 279 importer classified it as final and committed past
        /// every mood logged in Apple Health while the module was off.
        @Test("403 module.disabled is not a final refusal — it holds the anchor")
        func moduleDisabledIsNonterminal() {
            let refusal = MoodWriteOutcome.rejected(.moduleDisabled("mood"))
            #expect(MoodStateOfMindImporter.classification(of: refusal) == .nonterminal)
            let page = Self.page(
                classification: MoodStateOfMindImporter.classification(of: refusal),
                retryPersisted: false,
                retryFailed: false
            )
            #expect(HealthSyncCursorPolicy.installed.decide(page) == .hold(reason: .nonterminalEntry))
        }

        /// End to end over the real `APIClient` and `MockURLProtocol`: the server
        /// answers the mood POST with the v1.39 module-gate envelope (errorCode in
        /// `meta`), the page holds, and the same samples import once the module
        /// is on again — which is exactly what re-reading from a held anchor does.
        @Test("module off: the page holds and posts nothing more; module on: the same samples import")
        func moduleOffHoldsThenImports() async throws {
            let harness = try ModuleGateHarness()
            let moduleOn = OSAllocatedUnfairLock(initialState: false)
            let posts = OSAllocatedUnfairLock(initialState: 0)
            MockURLProtocol.install { req in
                posts.withLock { $0 += 1 }
                return ModuleGateHarness.moodResponse(for: req, moduleOn: moduleOn.withLock { $0 })
            }

            let samples = [0.5, -0.5].enumerated().map { offset, valence in
                HKStateOfMind(
                    date: Date(timeIntervalSince1970: 1_788_000_000 + TimeInterval(offset * 60)),
                    kind: .momentaryEmotion,
                    valence: valence,
                    labels: [],
                    associations: []
                )
            }

            let off = await harness.importer.consume(samples, requiring: harness.lease)
            #expect(HealthSyncCursorPolicy.installed.decide(off) == .hold(reason: .nonterminalEntry))
            #expect(posts.withLock { $0 } == 1, "the first 403 stops the page")
            #expect(await harness.outbox.snapshot.isEmpty, "a module refusal is not queued for a replay")

            moduleOn.withLock { $0 = true }
            let on = await harness.importer.consume(samples, requiring: harness.lease)
            #expect(HealthSyncCursorPolicy.installed.decide(on) == .commit)
            #expect(on.postedCount == 2)
            #expect(posts.withLock { $0 } == 3)
        }

        @Test("A page whose durable write was lost holds the anchor")
        func aLostEnqueueHoldsTheAnchor() {
            let page = Self.page(
                classification: MoodStateOfMindImporter.classification(of: .enqueueLost(.notPersisted("outbox lost"))),
                retryPersisted: false,
                retryFailed: true
            )
            #expect(
                HealthSyncCursorPolicy.installed.decide(page) == .hold(reason: .retryPersistenceFailed)
            )
        }

        @Test("A page whose durable write landed commits the anchor")
        func aQueuedWriteCommitsTheAnchor() {
            let page = Self.page(
                classification: MoodStateOfMindImporter.classification(
                    of: .queued(Self.entry, transport: .offline)
                ),
                retryPersisted: true,
                retryFailed: false
            )
            #expect(HealthSyncCursorPolicy.installed.decide(page) == .commit)
        }

        @Test("A cancelled page commits nothing, which is what makes the teardown drain safe")
        func aCancelledPageHolds() {
            var page = Self.page(classification: .terminalAccepted, retryPersisted: false, retryFailed: false)
            page = HealthSyncPageOutcome(
                postedCount: page.postedCount,
                entries: page.entries,
                transportThrew: false,
                durableRetryPersisted: false,
                durableRetryFailed: false,
                leaseIsCurrent: true,
                wasCancelled: true
            )
            #expect(HealthSyncCursorPolicy.installed.decide(page) == .hold(reason: .cancelled))
        }

        @Test("A page finished under a replaced account commits nothing")
        func aLateAccountPageHolds() {
            let page = HealthSyncPageOutcome(
                postedCount: 1,
                entries: [
                    HealthSyncEntryOutcome(index: 0, stableIdentity: "hk-mood-1", classification: .terminalAccepted)
                ],
                transportThrew: false,
                durableRetryPersisted: false,
                durableRetryFailed: false,
                leaseIsCurrent: false,
                wasCancelled: false
            )
            #expect(HealthSyncCursorPolicy.installed.decide(page) == .hold(reason: .leaseLost))
        }

        @Test("The mood cursor partition is owner-bound and hashes its owner")
        func theCursorPartitionIsOwnerBound() throws {
            let keyA = try #require(
                HealthSyncCursorKey(
                    ownerID: "account-a",
                    source: .mood,
                    typeIdentifier: MoodStateOfMindImporter.cursorTypeIdentifier
                )
            )
            let keyB = try #require(
                HealthSyncCursorKey(
                    ownerID: "account-b",
                    source: .mood,
                    typeIdentifier: MoodStateOfMindImporter.cursorTypeIdentifier
                )
            )
            #expect(keyA.storageKey != keyB.storageKey)
            #expect(!keyA.storageKey.contains("account-a"))
        }

        private static func page(
            classification: HealthSyncAcceptanceClass,
            retryPersisted: Bool,
            retryFailed: Bool
        ) -> HealthSyncPageOutcome {
            HealthSyncPageOutcome(
                postedCount: 1,
                entries: [
                    HealthSyncEntryOutcome(index: 0, stableIdentity: "hk-mood-1", classification: classification)
                ],
                transportThrew: false,
                durableRetryPersisted: retryPersisted,
                durableRetryFailed: retryFailed,
                leaseIsCurrent: true,
                wasCancelled: false
            )
        }
    }

    extension MoodStateOfMindDurabilityTests {
        /// C4 — a cancelled mood POST (`URLError.cancelled`: an expiring
        /// background window, or a failed certificate pin, which URLSession
        /// reports the same way) was classified as a final refusal and the
        /// anchor moved past a mood that was neither stored nor queued.
        @Test("a cancelled mood POST holds the page; the same samples import on the next sweep")
        func cancelledPostHoldsThenImports() async throws {
            let harness = try ModuleGateHarness()
            let cancelled = OSAllocatedUnfairLock(initialState: true)
            let posts = OSAllocatedUnfairLock(initialState: 0)
            MockURLProtocol.install { req in
                posts.withLock { $0 += 1 }
                if cancelled.withLock({ $0 }) { throw URLError(.cancelled) }
                return ModuleGateHarness.moodResponse(for: req, moduleOn: true)
            }
            let samples = [0.5, -0.5].enumerated().map { offset, valence in
                HKStateOfMind(
                    date: Date(timeIntervalSince1970: 1_788_100_000 + TimeInterval(offset * 60)),
                    kind: .momentaryEmotion,
                    valence: valence,
                    labels: [],
                    associations: []
                )
            }

            let interrupted = await harness.importer.consume(samples, requiring: harness.lease)
            #expect(HealthSyncCursorPolicy.installed.decide(interrupted) == .hold(reason: .nonterminalEntry))
            #expect(posts.withLock { $0 } == 1, "the page stops at the cancellation")
            #expect(await harness.outbox.snapshot.isEmpty)

            cancelled.withLock { $0 = false }
            let resumed = await harness.importer.consume(samples, requiring: harness.lease)
            #expect(HealthSyncCursorPolicy.installed.decide(resumed) == .commit)
            #expect(resumed.postedCount == 2)
        }
    }

    /// An admitted mood importer over the real `APIClient` + `MockURLProtocol`.
    struct ModuleGateHarness {
        /// Retained on purpose — the lease holds the registry weakly.
        let registry = AuthenticatedSessionLeaseRegistry()
        let lease: HealthSyncAuthenticatedLease
        let outbox: OutboxQueue
        let importer: MoodStateOfMindImporter

        init() throws {
            registry.activate(ownerID: "account-a")
            lease = try HealthSyncAuthenticatedLease.admit(
                from: registry,
                ownerID: "account-a",
                source: .mood,
                bearerProvider: { "bearer-a" }
            )
            let keychain = InMemoryKeychain()
            try keychain.setString("bearer-a", forKey: KeychainKey.authToken)
            try keychain.setString("account-a", forKey: KeychainKey.userID)
            let baseURL = try #require(URL(string: "https://test.healthlog.local"))
            let defaults = try #require(UserDefaults(suiteName: "mood-module-\(UUID().uuidString)"))
            let environment = AppEnvironment(baseURL: baseURL, bundleID: "dev.healthlog.app", appVersion: "1.0.4", buildNumber: "1")
            let api = APIClient(environment: environment, keychain: keychain, sessionConfiguration: .mock())
            outbox = try OutboxQueue(inMemory: true, currentOwnerProvider: { "account-a" })
            let admitted = lease
            importer = MoodStateOfMindImporter(
                store: HKHealthStore(),
                repo: MoodRepository(api: api, outbox: outbox),
                userID: "account-a",
                defaults: defaults,
                admission: { admitted },
                cursors: nil
            )
        }

        /// The v1.39 mood POST: 201 with the stored entry, or the module gate's
        /// 403 envelope with the code in `meta`.
        static func moodResponse(for req: URLRequest, moduleOn: Bool) -> (HTTPURLResponse, Data) {
            let body = moduleOn
                ? #"{"data":{"id":"srv-mood-1","mood":"GUT","tags":[],"moodLoggedAt":"2026-09-01T08:00:00.000Z","source":"MANUAL","note":null},"error":null}"#
                : #"{"data":null,"error":"Module \"mood\" is not enabled","meta":{"errorCode":"module.disabled","module":"mood"}}"#
            let response = HTTPURLResponse(
                url: req.url!,
                statusCode: moduleOn ? 201 : 403,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(body.utf8))
        }
    }

#endif

// swiftlint:enable force_unwrapping
